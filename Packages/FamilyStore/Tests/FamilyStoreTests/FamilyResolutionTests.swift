import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let artist = CatalogID(.artist, "artist-A")

    /// Known string order, so "lowest wins" is asserted, not discovered.
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

        // Old code bootstrapped a Family and Kid on a fetch miss; now it's the caller's.
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

    /// Two devices first-launching before import each bootstrap a household.
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

    /// The loser's household cascade-deletes anything still parented to it.
    @Test("The loser's kids and grown-ups are reparented, not cascaded away")
    func losersChildrenSurvive() throws {
        let context = try newStore()
        insertFamily(context, id: Fix.low, kids: ["Ada"], grownUps: ["Dad"])
        insertFamily(context, id: Fix.high, kids: ["Sam"], grownUps: ["Mum"])

        let resolved = try #require(try FamilyResolution.resolve(in: context))
        try context.save()

        #expect(Set(resolved.family.kids.map(\.name)) == ["Ada", "Sam"])
        #expect(Set(resolved.family.grownUps.map(\.name)) == ["Dad", "Mum"])

        // Fetched fresh: a row can look present in the array yet be gone from the store.
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

    /// CloudKit drops to-many order; `sortIndex` captures it — answer: first added.
    @Test("With no preference the first child added is the answer")
    func fallbackFollowsTheTypedOrder() throws {
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

        // `high` sorts last by id but was added first — roster order beat the tiebreak.
        #expect(family.kids.compactMap(\.sortIndex).sorted() == [0, 1])
        #expect(FamilyResolution.activeKid(of: family)?.id == Fix.high)
    }

    /// Tiebreak for uncaptured rows: identical everywhere, so an arbitrary id works.
    @Test("Uncaptured rows fall back to a stable tiebreak, and sort last")
    func uncapturedRowsSortLastAndStably() throws {
        let context = try newStore()
        let family = insertFamily(context)

        // Attached directly: nothing assigns an index, as for any pre-column row.
        for id in [Fix.high, Fix.low] {
            let kid = Kid(
                id: id, name: id.uuidString, mode: .allowOnly, unratedBehavior: .block, at: Fix.t0)
            context.insert(kid)
            kid.family = family
        }
        let captured = insertFamily(context, kids: ["Ada"]).kids.first

        #expect(family.kids.allSatisfy { $0.sortIndex == nil })
        #expect(family.orderedKids.map(\.id) == [Fix.low, Fix.high])
        #expect(FamilyResolution.activeKid(of: family)?.id == Fix.low)
        // And a captured row outranks an uncaptured one wherever they meet.
        #expect(captured?.sortIndex == 0)
    }

    /// Run late and the order it was meant to preserve is already sync-scrambled.
    @Test("Capturing the roster order is idempotent and never renumbers")
    func captureIsIdempotent() throws {
        let context = try newStore()
        let family = insertFamily(context)
        for name in ["Ada", "Sam", "Robin"] {
            let kid = Kid(name: name, mode: .allowOnly, unratedBehavior: .block, at: Fix.t0)
            context.insert(kid)
            kid.family = family
        }

        #expect(FamilyResolution.captureRosterOrder(of: family, at: Fix.t0) == 3)
        let first = family.orderedKids.map(\.name)

        // A second run does nothing — stops a later co-parent device from reordering it.
        #expect(FamilyResolution.captureRosterOrder(of: family, at: Fix.t0) == 0)
        #expect(family.orderedKids.map(\.name) == first)
    }

    @Test("A child added after the capture goes to the end, not the top")
    func lateArrivalGoesLast() throws {
        let context = try newStore()
        let family = insertFamily(context, kids: ["Ada", "Sam"])

        let late = Kid(name: "Robin", mode: .allowOnly, unratedBehavior: .block, at: Fix.t0)
        context.insert(late)
        family.addKid(late, at: Fix.t0)

        #expect(family.orderedKids.map(\.name) == ["Ada", "Sam", "Robin"])
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
    /// A tombstone, not a delete — a deleted row can't be enumerated to export.
    @Test("The row stays as a tombstone and leaves the policy")
    func removalRetracts() throws {
        let context = try newStore()
        let family = insertFamily(context, kids: ["Ada"])
        let kid = try #require(family.kids.first)

        let record = kid.addEntry(kind: .deny, id: Fix.artist, displayName: "A Band", at: Fix.t0)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)

        kid.removeEntry(record, at: Fix.t0 + PolicyEntryRecord.clockSkewWindow * 2)
        try context.save()

        // Still on disk and attached — the only thing that can carry the withdrawal along.
        #expect(kid.entries.count == 1)
        #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)

        // And out of the policy, which is what a parent asked for.
        #expect(kid.liveEntries.isEmpty)
        #expect(kid.buildPolicy().policy.entries.isEmpty)
    }
}
