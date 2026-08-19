import Foundation
import PolicyEngine
import SwiftData

/// The only unfiltered read — reaching `FilteredCatalog` instead would hide half.
@ModelActor
public actor ReviewReader {
    /// A cap, not a page — a half-read window would silently understate a count.
    public static let defaultPlayLimit = 2_000
    public static let defaultSearchLimit = 2_000
    public static let defaultBlockLimit = 10_000

    public enum Failure: Error, Equatable {
        case unknownKid(UUID)
    }

    // MARK: - Reading

    /// Unfiltered, unannotated, bounded — annotation happens above, on values.
    public func window(
        for kidID: UUID,
        in interval: DateInterval,
        at now: Date = .now,
        playLimit: Int = ReviewReader.defaultPlayLimit,
        searchLimit: Int = ReviewReader.defaultSearchLimit,
        blockLimit: Int = ReviewReader.defaultBlockLimit
    ) throws -> ReviewWindow {
        _ = try kid(kidID)

        var unreadable = 0

        let searches = try searchRows(kidID, interval, searchLimit).map(\.event)

        let plays = try playRows(kidID, interval, playLimit).compactMap { row -> PlayEvent? in
            guard let event = row.event else {
                unreadable += 1
                return nil
            }
            return event
        }

        let visits = try visitRows(kidID, interval, playLimit).compactMap { row -> VisitEvent? in
            guard let event = row.event else {
                unreadable += 1
                return nil
            }
            return event
        }

        let entries = try entrySnapshots(kidID)
        let blocks = try blockRows(kidID, interval, blockLimit).compactMap {
            row -> ReviewedBlock? in
            guard let event = row.event else {
                unreadable += 1
                return nil
            }
            // As it stands today — absent once approve-from-report removes it.
            let deniedBy: PolicyEntrySnapshot? =
                if case .deniedByParent(let id) = event.reason { entries[id] } else { nil }
            return ReviewedBlock(event: event, deniedBy: deniedBy)
        }

        return ReviewWindow(
            kidID: kidID,
            interval: interval,
            plays: plays,
            searches: searches,
            blocks: blocks,
            visits: visits,
            unreadable: unreadable,
            builtAt: now,
            coverage: try coverage(for: kidID, in: interval)
        )
    }

    /// Absent once the kid deletes it — no fallback, see `OriginDescription`.
    public func kidPlaylistNames(for kidID: UUID) throws -> [UUID: String] {
        let kid = try kid(kidID)
        return Dictionary(
            kid.playlists.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Snapshots only — a catalog suggestion logs as `playlist(_:)` instead.
    public func suggestedPlaylistNames(for kidID: UUID) throws -> [UUID: String] {
        let kid = try kid(kidID)
        return Dictionary(
            kid.suggestions.filter { $0.catalogID == nil }.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Bounded, so a long history over-reports novelty rather than ever hiding it.
    public func previouslyHeard(
        for kidID: UUID,
        before date: Date,
        limit: Int = ReviewReader.defaultPlayLimit
    ) throws -> Set<CatalogID> {
        var descriptor = FetchDescriptor<PlayEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID && $0.at < date },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return Set(try modelContext.fetch(descriptor).map { CatalogID(.song, $0.songID) })
    }

    /// Read here, not handed in — a report on a stale engine is worse than none.
    public func policy(for kidID: UUID) throws -> Policy {
        try kid(kidID).buildPolicy().policy
    }

    /// Always `.complete` now — added later, a swept week couldn't be told apart.
    private func coverage(for kidID: UUID, in interval: DateInterval) throws -> Coverage {
        let end = interval.end
        var descriptor = FetchDescriptor<WeeklySummaryRecord>(
            predicate: #Predicate { $0.kid?.id == kidID && $0.weekStart < end },
            sortBy: [SortDescriptor(\.weekStart, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let latest = try modelContext.fetch(descriptor).first else { return .complete }

        // Raw rows for the summarised week are gone; everything after it is whole.
        let rawFrom = max(interval.start, latest.weekStart.addingTimeInterval(7 * 24 * 60 * 60))
        guard rawFrom > interval.start else { return .complete }
        return .summarisedBefore(min(rawFrom, interval.end))
    }

    // Deliberately read-only — a delete here would leave the admin's context stale.

    // MARK: -

    // Not generic — `#Predicate` needs a concrete type, or it fails at runtime.

    private func searchRows(_ kidID: UUID, _ interval: DateInterval, _ limit: Int) throws
        -> [SearchEventRecord]
    {
        let start = interval.start
        let end = interval.end
        var descriptor = FetchDescriptor<SearchEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID && $0.at >= start && $0.at < end },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    private func playRows(_ kidID: UUID, _ interval: DateInterval, _ limit: Int) throws
        -> [PlayEventRecord]
    {
        let start = interval.start
        let end = interval.end
        var descriptor = FetchDescriptor<PlayEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID && $0.at >= start && $0.at < end },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    private func visitRows(_ kidID: UUID, _ interval: DateInterval, _ limit: Int) throws
        -> [VisitEventRecord]
    {
        let start = interval.start
        let end = interval.end
        var descriptor = FetchDescriptor<VisitEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID && $0.at >= start && $0.at < end },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    private func blockRows(_ kidID: UUID, _ interval: DateInterval, _ limit: Int) throws
        -> [BlockEventRecord]
    {
        let start = interval.start
        let end = interval.end
        var descriptor = FetchDescriptor<BlockEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID && $0.at >= start && $0.at < end },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    /// Keyed by `CatalogID` — MusicKit ids are unique only within one type.
    private func entrySnapshots(_ kidID: UUID) throws -> [CatalogID: PolicyEntrySnapshot] {
        let kid = try kid(kidID)
        var snapshots: [CatalogID: PolicyEntrySnapshot] = [:]
        for record in kid.entries {
            guard let entry = record.entry else { continue }
            snapshots[entry.id] = PolicyEntrySnapshot(
                id: entry.id,
                displayName: record.displayName,
                kind: entry.kind
            )
        }
        return snapshots
    }

    private func kid(_ id: UUID) throws -> Kid {
        var descriptor = FetchDescriptor<Kid>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let kid = try modelContext.fetch(descriptor).first else {
            throw Failure.unknownKid(id)
        }
        return kid
    }
}
