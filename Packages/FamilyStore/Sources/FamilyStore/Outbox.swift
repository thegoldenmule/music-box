import Foundation
import SwiftData

/// A row that was deleted, kept so the deletion can be told to another device.
///
/// **A deleted row leaves nothing to enumerate.** That is the whole problem: an
/// export driven by scanning the store can see everything that *exists*, and by
/// definition cannot see what does not. Without this, a favorite a child removed
/// or a playlist they threw away stays on a co-parent's device forever.
///
/// Most of this store does not need one. Policy entries retract, devices are
/// revoked, and both are tombstones already — a row that stays put with a
/// timestamp on it. This table is for the deletes that remain real, because
/// making *everything* a tombstone would mean a child's deleted playlists
/// accumulating on disk with no way to ever be rid of them, which is the
/// opposite of what a delete is for.
///
/// **Written in the same `save()` as the delete it describes**, which is what
/// makes it atomic. There is no window where the row is gone and the tombstone
/// is missing, because SwiftData commits both or neither — and that is why this
/// is a table rather than a side-effect somebody has to remember.
@Model
public final class PendingDeletionRecord {
    public private(set) var id: UUID = UUID()

    /// The name the record had on the server. Captured *before* the delete,
    /// because the name is derived from the row's content and there is no
    /// recovering it afterwards.
    public private(set) var recordName: String = ""

    public private(set) var recordType: String = ""
    public private(set) var deletedAt: Date = Date.distantPast

    /// Cleared once the deletion has been told to the server.
    public private(set) var exportedAt: Date?

    public init(
        id: UUID = UUID(),
        recordName: String,
        recordType: String,
        at: Date = .now
    ) {
        self.id = id
        self.recordName = recordName
        self.recordType = recordType
        self.deletedAt = at
    }

    public func markExported(at: Date = .now) { exportedAt = at }
}

/// The last version of a record this device and the server agreed on.
///
/// **A watermark could not do this job, and finding that out cost an
/// end-to-end test.** "Everything modified since time T" cannot tell a row
/// changed *here* from a row changed because we just *imported* it — an import
/// writes `modifiedAt` from the record, deliberately, so the imported row looks
/// exactly like a local edit to any timestamp comparison. Every device would
/// re-export its entire first import, and the other device would do the same
/// back. Two devices arguing forever about records neither of them changed.
///
/// So the question is asked per record instead: *is this row's `modifiedAt`
/// different from the one we last agreed on?* Marked on export and on import
/// alike, because both are agreement. A local edit moves `modifiedAt` and the
/// row becomes owed again; an import moves both together and it does not.
///
/// Device-local — it describes what this device has exchanged, not anything
/// about the household.
@Model
public final class SyncMarkRecord {
    public private(set) var recordName: String = ""
    public private(set) var syncedModifiedAt: Date = Date.distantPast

    public init(recordName: String, syncedModifiedAt: Date) {
        self.recordName = recordName
        self.syncedModifiedAt = syncedModifiedAt
    }

    func update(to date: Date) { syncedModifiedAt = date }
}

/// What this device still owes the server.
///
/// **There is no enqueue-at-every-write-site, and that is the design rather
/// than a shortcut.** The obvious shape for an outbox is a pending-changes table
/// that every mutation appends to, and it has two failure modes this store
/// cannot afford: a call site that forgets to enqueue is a change that silently
/// never syncs, and a crash between the mutation's `save()` and the enqueue
/// loses the change with nothing able to detect it.
///
/// Both disappear if the outbox is *derived* rather than maintained. Every
/// record in this store already carries `modifiedAt`, enforced structurally —
/// every stored property is `private(set)` and changes only through mutators
/// that stamp it. So "what has changed since we last exported" is a question the
/// store can already answer, and no call site has to remember anything.
///
/// That leaves exactly one gap, which is what ``PendingDeletionRecord`` covers:
/// a row that no longer exists cannot report its own `modifiedAt`.
///
/// **The cost, stated plainly.** This reads every synced row and filters in
/// memory rather than predicating in SQL. That is affordable only because the
/// synced set excludes the four event tables — the only ones with real volume —
/// which travel as `ActivitySegmentRecord` batches instead. If anything
/// high-volume is ever added to `SyncCoverage.syncedModels`, this becomes a
/// predicate or it becomes a problem.
public enum Outbox {
    /// One thing the server has not been told.
    public enum Change: Sendable, Equatable {
        case upsert(SyncedRecord)
        case delete(name: String, type: String)

        public var recordName: String {
            switch self {
            case .upsert(let record): record.name
            case .delete(let name, _): name
            }
        }
    }

    /// Everything this device has that the server has not agreed to, oldest
    /// first.
    ///
    /// **Oldest first is not cosmetic.** A record has to exist before the rows
    /// pointing at it can be resolved on the other side, and `modifiedAt` order
    /// is the closest thing available to causal order without a vector clock. It
    /// does not guarantee arrival order — nothing does — which is why the
    /// receiving side defers rather than drops what it cannot yet place.
    @MainActor
    public static func pending(in context: ModelContext) throws -> [Change] {
        var changes: [Change] = []
        let marks = Dictionary(
            try context.fetch(FetchDescriptor<SyncMarkRecord>())
                .map { ($0.recordName, $0.syncedModifiedAt) },
            uniquingKeysWith: { first, _ in first }
        )

        // **An orphan is skipped, not sent.** A row whose parent relationship
        // has been nulled cannot derive its natural key, and the old mapper
        // answered that with a fresh `UUID()` — so the same dead row uploaded
        // under a new name on every pass. The outbox never drained, the zone
        // grew by one record per orphan per sync, and nothing errored, because
        // from here it looked exactly like ordinary work.
        //
        // Skipping rather than repairing is deliberate: this is the read path,
        // and a read that silently rewrote the store would make every caller a
        // writer. `Outbox.orphans` is the repair, and it is a separate,
        // counted, explicit call.
        func collect<T: PersistentModel & SyncEncodable>(
            _ type: T.Type, _ touched: (T) -> Date
        ) throws {
            for row in try context.fetch(FetchDescriptor<T>()) {
                guard let name = row.syncRecordName, marks[name] != touched(row) else { continue }
                guard let record = row.syncRecord() else { continue }
                changes.append(.upsert(record))
            }
        }

        try collect(Family.self) { $0.modifiedAt }
        try collect(Kid.self) { $0.modifiedAt }
        try collect(GrownUp.self) { $0.modifiedAt }
        try collect(PolicyEntryRecord.self) { $0.modifiedAt }
        try collect(SandboxSettingRecord.self) { $0.modifiedAt }
        try collect(SuggestionRecord.self) { $0.modifiedAt }
        try collect(SuggestionEntryRecord.self) { $0.modifiedAt }
        try collect(FavoriteRecord.self) { $0.modifiedAt }
        try collect(PlaylistRecord.self) { $0.modifiedAt }
        try collect(PlaylistEntryRecord.self) { $0.modifiedAt }
        try collect(DeviceRecord.self) { $0.modifiedAt }
        try collect(PasscodeEpochRecord.self) { $0.modifiedAt }
        try collect(HistoryClearRecord.self) { $0.modifiedAt }
        try collect(ConsentRecord.self) { $0.modifiedAt }
        try collect(ActivitySegmentRecord.self) { $0.modifiedAt }
        try collect(WeeklySummaryRecord.self) { $0.modifiedAt }

        for tombstone in try context.fetch(FetchDescriptor<PendingDeletionRecord>())
        where tombstone.exportedAt == nil {
            changes.append(.delete(name: tombstone.recordName, type: tombstone.recordType))
        }

        return changes
    }

    /// Records that a row is going away, and then deletes it.
    ///
    /// **The order matters and so does the single `save()` the caller makes
    /// afterwards.** The tombstone captures the record's name while the row is
    /// still there to be asked; the delete follows in the same transaction. A
    /// caller that saves in between has opened the window this exists to close.
    /// `nonisolated` because the model methods that must call it are.
    ///
    /// The rest of this type fetches, which is why it is `@MainActor`; this one
    /// only inserts and deletes through a context a model already holds — the
    /// same thing `Kid.delete(_:)` does beside it. Requiring the main actor here
    /// is what kept ``removeFavorite`` and friends from writing tombstones at
    /// all, which is most of why deletions never reached a second device.
    nonisolated public static func delete<T: PersistentModel & SyncEncodable>(
        _ row: T,
        in context: ModelContext,
        at: Date = .now
    ) {
        // A row that cannot name itself was never on the server under any name,
        // so there is nothing to tell anyone about. It still has to go — that is
        // the whole point of deleting it — but a tombstone for a name nobody
        // ever saw is a delete instruction aimed at nothing.
        guard let name = row.syncRecordName else {
            context.delete(row)
            return
        }

        let tombstone = PendingDeletionRecord(
            recordName: name,
            recordType: T.syncRecordType,
            at: at
        )
        context.insert(tombstone)
        context.delete(row)
    }

    /// Drops tombstones the server has been told about and that no device could
    /// still be behind.
    ///
    /// Kept for a window rather than deleted on export, because a device that
    /// has been offline longer than the window has no way to learn about a
    /// deletion it never saw — it will re-upload the row it still holds. That is
    /// a real limit of this design and the window is where it is paid: too short
    /// and a stale device resurrects deleted rows, too long and tombstones
    /// accumulate. It is a number that wants measuring on real devices rather
    /// than choosing here.
    public static let tombstoneRetention: TimeInterval = 60 * 60 * 24 * 90

    /// Rows left on disk by a removal that only detached them.
    ///
    /// **These are not data anybody can reach.** Every query in the store is
    /// `kid?.id == kidID` or the equivalent, so a row whose parent is nil is
    /// invisible to the app that wrote it — a favourite the child un-hearted, a
    /// song pulled out of a playlist, a playlist thrown away. The removal the
    /// parent asked for happened on screen; only the disk half did not finish.
    ///
    /// Counted and returned rather than swept silently, for the reason
    /// ``FamilyResolution`` counts merged households: this deletes rows, and a
    /// repair that says nothing is indistinguishable from the bug it repairs.
    ///
    /// **Deliberately not called on launch.** It is offered, not imposed —
    /// deleting during an upgrade is the one thing there is no undo for, and
    /// `pending` already declines to export these, so nothing is broken while
    /// they sit there.
    @MainActor
    public static func orphans(in context: ModelContext) throws -> Int {
        var found = 0

        func reap<T: PersistentModel & SyncEncodable>(_ type: T.Type, _ isOrphan: (T) -> Bool)
            throws
        {
            for row in try context.fetch(FetchDescriptor<T>()) where isOrphan(row) {
                context.delete(row)
                found += 1
            }
        }

        // Only types whose key reads through a relationship can be orphaned;
        // the rest carry their own identifier and are always nameable.
        try reap(PolicyEntryRecord.self) { $0.kid == nil }
        try reap(SuggestionRecord.self) { $0.kid == nil }
        try reap(SuggestionEntryRecord.self) { $0.suggestion == nil }
        try reap(FavoriteRecord.self) { $0.kid == nil }
        try reap(PlaylistEntryRecord.self) { $0.playlist == nil }
        try reap(WeeklySummaryRecord.self) { $0.kid == nil }
        try reap(ActivitySegmentRecord.self) { $0.kidID == nil || $0.deviceID == nil }

        return found
    }

    @MainActor
    public static func sweepTombstones(
        olderThan cutoff: Date,
        in context: ModelContext
    ) throws -> Int {
        let doomed = try context.fetch(FetchDescriptor<PendingDeletionRecord>())
            .filter { $0.exportedAt != nil && $0.deletedAt < cutoff }
        for row in doomed { context.delete(row) }
        return doomed.count
    }
}

extension Outbox {
    /// Records that this device and the server now agree on a version.
    ///
    /// Called on **both** export and import. An import is agreement just as much
    /// as an export is — and marking only exports is what would leave every
    /// imported row looking locally-changed and owed straight back.
    @MainActor
    public static func markSynced(
        name: String, modifiedAt: Date, in context: ModelContext
    ) {
        let existing = try? context.fetch(FetchDescriptor<SyncMarkRecord>())
            .first { $0.recordName == name }
        if let existing {
            existing.update(to: modifiedAt)
        } else {
            context.insert(SyncMarkRecord(recordName: name, syncedModifiedAt: modifiedAt))
        }
    }

    /// Convenience for a whole record.
    @MainActor
    public static func markSynced(_ record: SyncedRecord, in context: ModelContext) {
        guard let touched = record.date(Field.modifiedAt) else { return }
        markSynced(name: record.name, modifiedAt: touched, in: context)
    }
}
