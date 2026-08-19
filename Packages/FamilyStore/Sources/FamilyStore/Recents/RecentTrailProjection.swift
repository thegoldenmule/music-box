import Foundation
import PolicyEngine
import SwiftData

/// Same save as the causing event — write and read model can't disagree.
enum RecentTrailProjection {
    /// Whole window, not a fold — retraction rules need it all; live shares this.
    static func recompute(for kid: Kid, in context: ModelContext) throws {
        let kidID = kid.id
        var descriptor = FetchDescriptor<VisitEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        descriptor.fetchLimit = RecentTrail.window

        // Newest first is what a limit means; reversed for arrival order.
        let visits = try context.fetch(descriptor).compactMap(\.event).reversed()
        reconcile(kid, to: RecentTrail.shelf(from: Array(visits)), in: context)
    }

    /// The stored trail, newest first, skipping rows that will not read back.
    static func trail(of kid: Kid) -> [RecentEntry] {
        kid.recentTrail
            .compactMap(\.entry)
            .sorted { $0.at > $1.at }
    }

    /// An empty trail is never stale — nothing to replay for a kid who's done nothing.
    static func isStale(_ kid: Kid) -> Bool {
        guard !kid.recentTrail.isEmpty else { return false }
        return kid.recentTrail.contains { $0.version != RecentTrail.version }
    }

    /// After a sweep this shelf is shorter, correctly — arrivals are gone, not hidden.
    static func rebuild(for kid: Kid, in context: ModelContext) throws {
        let kidID = kid.id
        var descriptor = FetchDescriptor<VisitEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        descriptor.fetchLimit = RecentTrail.window

        let visits = try context.fetch(descriptor).compactMap(\.event).reversed()
        reconcile(kid, to: RecentTrail.shelf(from: Array(visits)), in: context, force: true)
    }

    static func clear(_ kid: Kid, in context: ModelContext) {
        for row in kid.recentTrail { context.delete(row) }
        kid.clearRecentTrail()
    }

    // MARK: -

    /// Smallest edit set to reach `next`; `force` rewrites survivors too.
    private static func reconcile(
        _ kid: Kid,
        to next: [RecentEntry],
        in context: ModelContext,
        force: Bool = false
    ) {
        var existing: [CatalogID: RecentTrailRecord] = [:]
        for row in kid.recentTrail {
            guard let entry = row.entry else {
                // Unreadable and unusable — the one place it gets cleaned up.
                context.delete(row)
                kid.remove(row)
                continue
            }
            existing[entry.catalogID] = row
        }

        let keep = Set(next.map(\.catalogID))
        for (id, row) in existing where !keep.contains(id) {
            context.delete(row)
            kid.remove(row)
        }

        for entry in next {
            guard let row = existing[entry.catalogID] else {
                let row = RecentTrailRecord(entry: entry)
                context.insert(row)
                kid.attach(row)
                continue
            }
            if force {
                context.delete(row)
                kid.remove(row)
                let replacement = RecentTrailRecord(entry: entry)
                context.insert(replacement)
                kid.attach(replacement)
            } else if row.at != entry.at || row.version != RecentTrail.version {
                row.refresh(at: entry.at)
            }
        }
    }
}
