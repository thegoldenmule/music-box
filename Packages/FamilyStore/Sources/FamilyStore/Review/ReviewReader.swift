import Foundation
import PolicyEngine
import SwiftData

/// The parent's read of one kid's history. **The only one.**
///
/// Every review surface goes through here. That is a seam rather than a habit,
/// because the rule this component turns on is the opposite of the rest of the
/// app's: nothing here is filtered by policy, and a screen that reached past it
/// into `FilteredCatalog` or `MergedLibrary.favorites()` would show a parent
/// their child's history with the interesting half quietly missing. There is no
/// method on this type that removes a row.
///
/// A third context, distinct from the main one the admin writes policy on and
/// from ``EventLog``'s, which the kid's session writes events on. Reading never
/// blocks a write, which keeps the rule that logging never delays playback.
///
/// **Reading a report writes nothing.** A parent opening this must never appear
/// in it, and this is the one place in the app where that mistake is easy to
/// make.
@ModelActor
public actor ReviewReader {
    /// How many rows of one kind a single window will hold.
    ///
    /// A cap rather than a page, because the grouped view is a summary of the
    /// whole window and a half-read window would silently understate a count.
    /// Blocks get the larger share: a level 2 kid generates one row per filtered
    /// result per search, and the over-fetch loop discards a multiple of every
    /// page.
    public static let defaultPlayLimit = 2_000
    public static let defaultSearchLimit = 2_000
    public static let defaultBlockLimit = 10_000

    public enum Failure: Error, Equatable {
        case unknownKid(UUID)
    }

    // MARK: - Reading

    /// Everything the store holds for this kid over this interval.
    ///
    /// Unfiltered, unannotated and bounded. The engine is not consulted here at
    /// all — annotation happens above, on values, where it is pure.
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

        let entries = try entrySnapshots(kidID)
        let blocks = try blockRows(kidID, interval, blockLimit).compactMap {
            row -> ReviewedBlock? in
            guard let event = row.event else {
                unreadable += 1
                return nil
            }
            // The entry a `deniedByParent` names, as it stands today — absent
            // once the parent has removed it, which is what approve-from-report
            // does.
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
            unreadable: unreadable,
            builtAt: now,
            coverage: try coverage(for: kidID, in: interval)
        )
    }

    /// Names of this kid's own playlists, for rendering a `kidPlaylist` origin.
    ///
    /// Absent once the kid deletes one, and there is no fallback — see
    /// ``OriginDescription/kidPlaylist(_:name:)``.
    public func kidPlaylistNames(for kidID: UUID) throws -> [UUID: String] {
        let kid = try kid(kidID)
        return Dictionary(
            kid.playlists.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Songs this kid played before a date, for `firstTimeHeard`.
    ///
    /// Bounded like everything else here, which means a kid with a very long
    /// history can have a song read as first-time-heard when it is not. That
    /// error runs one way — it over-reports novelty rather than hiding it — and
    /// a report is not forensic.
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

    /// The kid's policy, for annotating a window.
    ///
    /// Read here rather than handed in, so the report is judged by exactly the
    /// engine the kid's own device builds. A report that disagreed with the app
    /// would be worse than none.
    public func policy(for kidID: UUID) throws -> Policy {
        try kid(kidID).buildPolicy().policy
    }

    /// Whether a summary overlaps the interval, and where the raw rows start.
    ///
    /// Always `.complete` today: nothing writes a summary yet. It is computed
    /// from the first release anyway, because once the sweep exists an already
    /// swept week would otherwise read as a week the kid did nothing, with no
    /// way afterwards to tell which weeks those were.
    private func coverage(for kidID: UUID, in interval: DateInterval) throws -> Coverage {
        let end = interval.end
        var descriptor = FetchDescriptor<WeeklySummaryRecord>(
            predicate: #Predicate { $0.kid?.id == kidID && $0.weekStart < end },
            sortBy: [SortDescriptor(\.weekStart, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let latest = try modelContext.fetch(descriptor).first else { return .complete }

        // A summary exists for a week inside this window, so the raw rows for
        // that week are gone. Everything from the end of the summarised week
        // onward is still whole.
        let rawFrom = max(interval.start, latest.weekStart.addingTimeInterval(7 * 24 * 60 * 60))
        guard rawFrom > interval.start else { return .complete }
        return .summarisedBefore(min(rawFrom, interval.end))
    }

    // Deleting is deliberately **not** here. This actor only reads.
    //
    // Not squeamishness about mixing verbs: the admin already holds the kid
    // records on its own context, with their favorites and playlists
    // materialised, and a delete run from a second context would leave that copy
    // holding rows the store no longer has. See ``Kid/deleteEverything()``,
    // which the admin calls on the context that owns those objects — awaited,
    // with its failure surfaced, like every other write a parent makes.

    // MARK: -

    // Three near-identical fetches rather than one generic over a protocol.
    // `#Predicate` resolves its key paths against a concrete model type; written
    // once over a `Row: EventRow` it compiles and then fails at run time, which
    // is the worst of the three options.

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

    /// Today's entries, by identifier, for resolving `deniedByParent`.
    ///
    /// Keyed by ``CatalogID`` and not by its raw string: MusicKit identifiers
    /// are only unique within a type, so an album could otherwise answer for a
    /// song.
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
