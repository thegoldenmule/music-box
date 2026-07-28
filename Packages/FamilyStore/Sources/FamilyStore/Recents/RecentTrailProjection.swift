import Foundation
import PolicyEngine
import SwiftData

/// Keeps ``RecentTrailRecord`` in step with ``VisitEventRecord``.
///
/// Applied **in the same save as the event that caused it**, so the write model
/// and its read model can never disagree — there is no window in which a visit
/// exists and the shelf has not heard about it, and no separate failure mode to
/// reason about.
///
/// The decisions all live in ``RecentTrail``, which is pure. What is here is the
/// unglamorous half: turning a new trail into the smallest set of row edits that
/// gets there. That matters more than it looks, because this table syncs — a
/// naive delete-everything-and-reinsert would rewrite fifty CloudKit records
/// every time a kid opened an album.
enum RecentTrailProjection {
    /// Recomputes the shelf from the kid's recent arrivals.
    ///
    /// The whole window every time, rather than folding the one new visit in.
    /// Two of the shelf's three rules look across all of it — playing a track
    /// *retracts* that artist's own tile — so an incremental update would have
    /// to un-decide, which a fold cannot do. It also means the live path and the
    /// rebuild path are the same call and cannot drift apart.
    static func recompute(for kid: Kid, in context: ModelContext) throws {
        let kidID = kid.id
        var descriptor = FetchDescriptor<VisitEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        descriptor.fetchLimit = RecentTrail.window

        // Fetched newest first because that is what a limit means; reversed
        // because "contiguous" is a fact about the order things happened in.
        let visits = try context.fetch(descriptor).compactMap(\.event).reversed()
        reconcile(kid, to: RecentTrail.shelf(from: Array(visits)), in: context)
    }

    /// The stored trail, newest first, skipping rows that will not read back.
    static func trail(of kid: Kid) -> [RecentEntry] {
        kid.recentTrail
            .compactMap(\.entry)
            .sorted { $0.at > $1.at }
    }

    /// Whether the stored trail was built by a different version of the walk.
    ///
    /// An empty trail is never stale — there is nothing to have got wrong, and
    /// treating it as stale would replay the whole event table on every launch
    /// for a kid who has done nothing.
    static func isStale(_ kid: Kid) -> Bool {
        guard !kid.recentTrail.isEmpty else { return false }
        return kid.recentTrail.contains { $0.version != RecentTrail.version }
    }

    /// Throws the shelf away and rebuilds it.
    ///
    /// The same computation as ``recompute(for:in:)`` — a rebuild is not a
    /// special path, it is the ordinary one run with `force` so that rows
    /// carrying an old ``RecentTrail/version`` stop doing so.
    ///
    /// After a retention sweep this yields a shorter shelf than it would have
    /// before, and that is correct rather than unfortunate: the arrivals really
    /// are gone, and a shelf that claimed otherwise would be inventing history.
    /// ``RecentsProjector/retentionFloor(for:)`` is what keeps the sweep from
    /// reaching that far.
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

    /// The smallest set of edits that turns the stored rows into `next`.
    ///
    /// - Parameter force: rewrite surviving rows even when nothing about them
    ///   changed. Only a rebuild wants this, and only so that rows carrying an
    ///   old ``RecentTrail/version`` stop doing so.
    private static func reconcile(
        _ kid: Kid,
        to next: [RecentEntry],
        in context: ModelContext,
        force: Bool = false
    ) {
        var existing: [CatalogID: RecentTrailRecord] = [:]
        for row in kid.recentTrail {
            guard let entry = row.entry else {
                // Unreadable, and nothing above can use it. Dropping it here is
                // the one place it gets cleaned up.
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
