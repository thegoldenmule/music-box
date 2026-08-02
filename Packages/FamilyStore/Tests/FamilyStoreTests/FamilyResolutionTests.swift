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
    /// ordering, so `first` on it is not a choice anybody made. What replaces it
    /// is the order a parent actually put their children in, captured into
    /// `sortIndex` — so the answer is the *first* child added, whatever their
    /// identifier sorts like.
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

        // `high` was added first, and sorts *last* by identifier — so this
        // asserts the roster order beat the tiebreak rather than coinciding
        // with it.
        #expect(family.kids.compactMap(\.sortIndex).sorted() == [0, 1])
        #expect(FamilyResolution.activeKid(of: family)?.id == Fix.high)
    }

    /// The tiebreak underneath, for rows nothing has captured an order for. It
    /// has to be identical on every device and every launch; the identifier is
    /// arbitrary and does that.
    @Test("Uncaptured rows fall back to a stable tiebreak, and sort last")
    func uncapturedRowsSortLastAndStably() throws {
        let context = try newStore()
        let family = insertFamily(context)

        // Attached directly, so nothing assigns an index — the state every row
        // written before the column existed is in.
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

    /// The capture is the whole point: run it late and the order it was meant to
    /// preserve has already been through a sync that does not preserve it.
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

        // A second run finds nothing to do, and cannot reshuffle what the first
        // one decided — which is what stops a co-parent's device joining later
        // from reordering a roster that has already been captured.
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
    /// This one moved twice and both moves are worth keeping.
    ///
    /// It began as `removeAll()` on the relationship alone, which nulls the
    /// inverse and leaves the row where no query can reach it — every query here
    /// is `kid?.id == kidID` — so a parent watched the deny disappear while it
    /// went on being a deny for nobody. That was fixed by deleting through the
    /// context, which is right for one writer and wrong for two: **a deleted row
    /// leaves nothing to enumerate**, so the removal can never be exported and a
    /// co-parent's device keeps the entry forever.
    ///
    /// So it is a retraction. The row stays, reachable by every query, and it is
    /// `buildPolicy()` that leaves it out.
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

        // Still on disk and still attached — that is the tombstone, and it is
        // the only thing that can carry the withdrawal to another device.
        #expect(kid.entries.count == 1)
        #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)

        // And out of the policy, which is what a parent asked for.
        #expect(kid.liveEntries.isEmpty)
        #expect(kid.buildPolicy().policy.entries.isEmpty)
    }
}
