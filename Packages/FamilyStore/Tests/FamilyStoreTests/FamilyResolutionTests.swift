import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let artist = CatalogID(.artist, "artist-A")

    /// Two identifiers whose string order is known, so "lowest wins" is a fact
    /// the test asserts rather than one it discovers.
    static let low = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    static let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-0000000000FF")!
}

@MainActor
private func newStore() throws -> ModelContext {
    ModelContext(try FamilyStore.inMemoryContainer())
}

@MainActor
@discardableResult
private func insertFamily(
    _ context: ModelContext,
    id: UUID = UUID(),
    kids: [String] = [],
    grownUps: [String] = []
) -> Family {
    let family = Family(id: id, at: Fix.t0)
    context.insert(family)
    for name in kids {
        let kid = Kid(name: name, mode: .denyPlusAuto, unratedBehavior: .block, at: Fix.t0)
        context.insert(kid)
        family.addKid(kid, at: Fix.t0)
    }
    for name in grownUps {
        let grownUp = GrownUp(name: name, at: Fix.t0)
        context.insert(grownUp)
        family.addGrownUp(grownUp, at: Fix.t0)
    }
    return family
}

// MARK: - One household

@Suite("Resolving the household")
@MainActor
struct ResolvingTheHousehold {
    @Test("An empty store resolves to nobody, and creates nothing")
    func emptyStoreCreatesNothing() throws {
        let context = try newStore()

        #expect(try FamilyResolution.resolve(in: context) == nil)

        // The old code created a Family *and* a kid named "Kid" as a side effect
        // of the fetch missing. Bootstrapping is the caller's call, and a device
        // that cannot reach the zone is not entitled to make it.
        #expect(try context.fetch(FetchDescriptor<Family>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Kid>()).isEmpty)
    }

    @Test("One household resolves to itself with nothing merged")
    func singleHousehold() throws {
        let context = try newStore()
        let family = insertFamily(context, id: Fix.low, kids: ["Ada"])

        let resolved = try #require(try FamilyResolution.resolve(in: context))
        #expect(resolved.family.id == family.id)
        #expect(resolved.resolution.mergedAway == 0)
    }

    /// The failure this exists for: two devices that first-launch before the
    /// first import each bootstrap a household, and afterwards an unsorted fetch
    /// returns an arbitrary one — potentially a different one per launch.
    @Test("Two households converge on the lowest identifier, from either order")
    func duplicatesConverge() throws {
        for order in [[Fix.low, Fix.high], [Fix.high, Fix.low]] {
            let context = try newStore()
            for id in order { insertFamily(context, id: id) }

            let resolved = try #require(try FamilyResolution.resolve(in: context))
            #expect(resolved.family.id == Fix.low)
            #expect(resolved.resolution.mergedAway == 1)
            #expect(try context.fetch(FetchDescriptor<Family>()).count == 1)
        }
    }

    /// The half that matters: the loser's household is deleted under a cascade
    /// rule, so anything still parented to it goes with it. A child's playlists
    /// hang off `Kid`.
    @Test("The loser's kids and grown-ups are reparented, not cascaded away")
    func losersChildrenSurvive() throws {
        let context = try newStore()
        insertFamily(context, id: Fix.low, kids: ["Ada"], grownUps: ["Dad"])
        insertFamily(context, id: Fix.high, kids: ["Sam"], grownUps: ["Mum"])

        let resolved = try #require(try FamilyResolution.resolve(in: context))
        try context.save()

        #expect(Set(resolved.family.kids.map(\.name)) == ["Ada", "Sam"])
        #expect(Set(resolved.family.grownUps.map(\.name)) == ["Dad", "Mum"])

        // Fetched fresh rather than read off the relationship: a row can be
        // present in an array and gone from the store, which is the whole
        // family of bugs this stage is about.
        #expect(try context.fetch(FetchDescriptor<Kid>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<GrownUp>()).count == 2)
        for kid in try context.fetch(FetchDescriptor<Kid>()) {
            #expect(kid.family?.id == Fix.low)
        }
    }
}

// MARK: - Which child

@Suite("Choosing the active kid")
@MainActor
struct ChoosingTheActiveKid {
    @Test("A preference that names somebody wins")
    func preferenceWins() throws {
        let context = try newStore()
        let family = insertFamily(context, kids: ["Ada", "Sam"])
        let sam = try #require(family.kids.first { $0.name == "Sam" })

        #expect(FamilyResolution.activeKid(of: family, preferring: sam.id)?.id == sam.id)
    }

    /// `kids` is a to-many relationship and CloudKit does not preserve to-many
    /// ordering, so `first` is not a choice anybody made. Stable is the floor.
    @Test("With no preference the answer is the same every time")
    func fallbackIsDeterministic() throws {
        let context = try newStore()
        let family = insertFamily(context)
        for id in [Fix.high, Fix.low] {
            let kid = Kid(
                id: id,
                name: id.uuidString,
                mode: .allowOnly,
                unratedBehavior: .block,
                at: Fix.t0
            )
            context.insert(kid)
            family.addKid(kid, at: Fix.t0)
        }

        #expect(FamilyResolution.activeKid(of: family)?.id == Fix.low)
    }

    @Test("A preference naming nobody falls back rather than resolving to nil")
    func unknownPreferenceFallsBack() throws {
        let context = try newStore()
        let family = insertFamily(context, kids: ["Ada"])

        #expect(FamilyResolution.activeKid(of: family, preferring: UUID()) != nil)
    }

    @Test("A household with no kids has no active kid")
    func emptyHouseholdHasNoKid() throws {
        let context = try newStore()
        let family = insertFamily(context)

        #expect(FamilyResolution.activeKid(of: family) == nil)
    }
}

// MARK: - Delete means delete

@Suite("Removing a policy entry")
@MainActor
struct RemovingAPolicyEntry {
    /// `removeAll()` on a relationship nulls the inverse and leaves the row on
    /// disk. Every query here is `kid?.id == kidID`, so the orphan is invisible
    /// — a parent watches the deny disappear while it goes on being a deny for
    /// nobody. This returned one row before the fix.
    @Test("The row leaves the store, not just the relationship")
    func removalDeletes() throws {
        let context = try newStore()
        let family = insertFamily(context, kids: ["Ada"])
        let kid = try #require(family.kids.first)

        let record = kid.addEntry(kind: .deny, id: Fix.artist, displayName: "A Band", at: Fix.t0)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)

        kid.removeEntry(record, at: Fix.t0)
        try context.save()

        #expect(kid.entries.isEmpty)
        #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).isEmpty)
    }
}
