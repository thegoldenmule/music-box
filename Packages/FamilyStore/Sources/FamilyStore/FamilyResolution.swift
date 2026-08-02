import Foundation
import SwiftData

/// Which household this store holds, and which child the app opens into.
///
/// Both answers used to be one line in the app layer: fetch one `Family` with no
/// predicate and no sort, then take `kids.first`. Under one device and one
/// writer that is correct by accident — there is exactly one of each, so an
/// arbitrary pick is the only pick. Neither property survives a second device,
/// and both failures are the quiet kind:
///
/// - **Two households.** Two devices that first-launch before the first import
///   each create one, which is the *normal* order rather than a race: the app is
///   usable offline and enrolment is asynchronous. Afterwards an unsorted
///   `fetchLimit = 1` returns an arbitrary one, potentially a different one per
///   device and per launch, and a share hangs off exactly one of them. The other
///   parent then curates a household nobody can see. The safety half is sharper
///   than the data-loss half: a parent adds a deny, watches it appear, and the
///   child's device is governed by a `Kid` in the other household that the deny
///   never reached.
/// - **An arbitrary kid.** `kids` is a to-many relationship, and CloudKit does
///   not preserve to-many ordering, so `first` is not a choice anybody made. A
///   seven-year-old's iPad opening into his twelve-year-old sister's
///   `reportOnly` sandbox is three failures at once — the wrong policy level,
///   another child's library, and every play filed under the wrong name — and
///   all three look like the app working.
///
/// Both live here rather than in the app because they decide *which policy is in
/// force*, which puts them in the same category as the engine itself: worth
/// testing exhaustively, and untestable where they were. There is no app test
/// target.
///
/// A namespace of its own rather than an extension on ``FamilyStore``: inside a
/// module called `FamilyStore`, `extension FamilyStore` is ambiguous with the
/// module itself and does not compile.
public enum FamilyResolution {
    /// What ``resolve(in:at:)`` found, and what it had to do about it.
    public struct Resolution: Sendable, Equatable {
        /// How many duplicate households were folded into the survivor. Zero on
        /// every healthy store; non-zero is worth saying out loud in the admin
        /// rather than repairing in silence, because a parent who has been
        /// curating into the losing household deserves to know why their lists
        /// just changed.
        public let mergedAway: Int

        public init(mergedAway: Int) {
            self.mergedAway = mergedAway
        }
    }

    /// The one household in this store, or `nil` when there is not one yet.
    ///
    /// **Never creates one.** Bootstrapping is the caller's decision and a
    /// consequential one — a device that creates a household because it could
    /// not reach the zone has forked the family — so this returns the honest
    /// answer and lets the caller decide whether it is entitled to act on it.
    /// The old code created a `Family` *and* a kid named `"Kid"` as a side
    /// effect of a fetch miss, and did it on a guard that also fired when a real
    /// household happened to have no children in it yet.
    ///
    /// **Merges rather than picks** when it finds more than one. The survivor is
    /// the lowest identifier, which is arbitrary but *stable* — every device
    /// reaches the same verdict with no coordination, which is the property that
    /// matters and the one `first` never had. The losers' kids and grown-ups are
    /// reparented before their households are deleted, so the cascade rule takes
    /// an empty container rather than a child's playlists.
    @discardableResult
    public static func resolve(
        in context: ModelContext,
        at: Date = .now
    ) throws -> (family: Family, resolution: Resolution)? {
        let households = try context.fetch(FetchDescriptor<Family>())
            .sorted { $0.id.uuidString < $1.id.uuidString }

        guard let survivor = households.first else { return nil }
        let losers = households.dropFirst()
        guard !losers.isEmpty else { return (survivor, Resolution(mergedAway: 0)) }

        for loser in losers {
            // Snapshotted because reparenting mutates the array being walked:
            // `addKid` sets the inverse, which takes the row out of `loser.kids`
            // underneath the loop.
            for kid in Array(loser.kids) {
                loser.removeKid(kid, at: at)
                survivor.addKid(kid, at: at)
            }
            for grownUp in Array(loser.grownUps) {
                loser.removeGrownUp(grownUp, at: at)
                survivor.addGrownUp(grownUp, at: at)
            }
            context.delete(loser)
        }

        return (survivor, Resolution(mergedAway: losers.count))
    }

    /// Writes down the order the two rosters are already in, once.
    ///
    /// **This one has a deadline, and it is the reason it exists at all.** The
    /// order a parent typed their children and their grown-ups in is not stored
    /// anywhere — it is the insertion order of a to-many relationship, and it
    /// has always been what the admin and the kid's home screen render. That is
    /// fine while one device owns the store and it stops being true the moment
    /// anything syncs: CloudKit does not preserve to-many ordering, and this
    /// codebase already says so about a sibling relationship.
    ///
    /// So the order is readable **now** and gone afterwards. Capturing it is not
    /// a migration in the SwiftData sense — no stage, no frozen schema, nothing
    /// rewritten but two integers per row — but it is a one-way door in the same
    /// way: run it late and there is nothing left to read.
    ///
    /// **Idempotent, and it never renumbers.** A row that already has an index
    /// keeps it; only `nil` rows are filled, and they are appended after the
    /// highest index already assigned. So a second parent's device joining later
    /// cannot reshuffle a roster that has already been captured, and adding a
    /// child after the capture does not disturb the ones above them.
    ///
    /// For a grown-up this is not cosmetic. Their shelves appear on a child's
    /// own home screen in this order, and "From Dad" above "From Mum" is
    /// something the child reads every day.
    @discardableResult
    public static func captureRosterOrder(of family: Family, at: Date = .now) -> Int {
        var captured = 0

        func fill<Row>(
            _ rows: [Row],
            index: (Row) -> Int?,
            assign: (Row, Int) -> Void
        ) {
            var next = (rows.compactMap(index).max() ?? -1) + 1
            for row in rows where index(row) == nil {
                assign(row, next)
                next += 1
                captured += 1
            }
        }

        fill(family.kids, index: \.sortIndex) { $0.setSortIndex($1, at: at) }
        fill(family.grownUps, index: \.sortIndex) { $0.setSortIndex($1, at: at) }

        return captured
    }

    /// The child the app opens into.
    ///
    /// `preferring` is the device's own answer — the bound kid, once
    /// `DeviceRecord` exists — and it wins whenever it names somebody still in
    /// the household. It is passed rather than read so that this stays a
    /// function of its arguments.
    ///
    /// The fallback is the first of ``Family/orderedKids``, which is the order a
    /// parent actually put their children in — captured by
    /// ``captureRosterOrder(of:at:)`` — with the identifier breaking ties. It
    /// used to be the lowest identifier outright, which was stable but
    /// meaningless; stable is the floor and this clears it.
    ///
    /// **A preference that names nobody falls back rather than failing.** That
    /// is right for today, when the preference is only a restored selection, and
    /// it is wrong the moment it becomes a binding: a device bound to a kid who
    /// is not in the household must lock, never open a sibling. When
    /// `DeviceRecord` arrives that rule belongs in a resolver of its own, and
    /// this one keeps its softer job of picking a default.
    public static func activeKid(of family: Family, preferring id: UUID? = nil) -> Kid? {
        if let id, let preferred = family.kids.first(where: { $0.id == id }) {
            return preferred
        }
        return family.orderedKids.first
    }
}
