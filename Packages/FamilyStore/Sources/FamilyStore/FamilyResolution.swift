import Foundation
import SwiftData

/// Replaces an unsorted `kids.first`, correct by accident under one device.
///
/// **Two quiet failures.** Two devices first-launching before import each
/// create a household; a share then hangs off one, and a parent's deny in the
/// other never reaches the child it was meant for. Separately, CloudKit drops
/// to-many order, so an arbitrary `kids.first` can open a sibling's sandbox —
/// wrong policy level, wrong library, wrong name on every play.
///
/// Lives here, not the app, because it decides which policy is in force —
/// the same category as the engine, and there is no app test target.
public enum FamilyResolution {
    /// What ``resolve(in:at:)`` found, and what it had to do about it.
    public struct Resolution: Sendable, Equatable {
        /// Non-zero is shown, not silently repaired — a parent curated the losing one.
        public let mergedAway: Int

        public init(mergedAway: Int) {
            self.mergedAway = mergedAway
        }
    }

    /// Never creates one; merges duplicates onto the lowest id, uncoordinated.
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
            // Snapshotted — `addKid`'s inverse mutates `loser.kids` under the loop.
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

    /// Has a deadline — sync drops insertion order — and never renumbers once run.
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

    /// Falls back, never fails, on an unknown `preferring` — right until it binds.
    public static func activeKid(of family: Family, preferring id: UUID? = nil) -> Kid? {
        if let id, let preferred = family.kids.first(where: { $0.id == id }) {
            return preferred
        }
        return family.orderedKids.first
    }
}
