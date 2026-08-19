import Foundation
import SwiftData

/// Kept so a delete reaches another device — a gone row can't be enumerated.
@Model
public final class PendingDeletionRecord {
    public private(set) var id: UUID = UUID()

    /// Server name, captured before delete — unrecoverable afterward.
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

/// Per-record, not a watermark — import writes `modifiedAt` too.
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

/// Derived from `modifiedAt`, never enqueued — no call site to forget.
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

    /// Oldest first — `modifiedAt` approximates causal order, no vector clock.
    @MainActor
    public static func pending(in context: ModelContext) throws -> [Change] {
        var changes: [Change] = []
        let marks = Dictionary(
            try context.fetch(FetchDescriptor<SyncMarkRecord>())
                .map { ($0.recordName, $0.syncedModifiedAt) },
            uniquingKeysWith: { first, _ in first }
        )

        // Skips, doesn't repair — a read path must never silently write.
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

    /// Tombstone then delete, one save — `nonisolated` since callers must be too.
    nonisolated public static func delete<T: PersistentModel & SyncEncodable>(
        _ row: T,
        in context: ModelContext,
        at: Date = .now
    ) {
        // Never on the server under any name — deletes with no tombstone needed.
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

    /// A window: too short resurrects deletes, too long piles up tombstones.
    public static let tombstoneRetention: TimeInterval = 60 * 60 * 24 * 90

    /// Never on launch — an upgrade-time delete has no undo, so it's asked for.
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

        // Only types whose key reads through a relationship can be orphaned.
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
    /// Marked on export and import alike — an import is agreement too.
    @MainActor
    public static func markSynced(
        name: String, modifiedAt: Date, in context: ModelContext
    ) {
        var descriptor = FetchDescriptor<SyncMarkRecord>(
            predicate: #Predicate { $0.recordName == name }
        )
        descriptor.fetchLimit = 1

        if let existing = try? context.fetch(descriptor).first {
            existing.update(to: modifiedAt)
        } else {
            context.insert(SyncMarkRecord(recordName: name, syncedModifiedAt: modifiedAt))
        }
    }

    /// One pass over the marks, not one predicate fetch per record.
    @MainActor
    public static func markSynced(_ records: [SyncedRecord], in context: ModelContext) {
        guard !records.isEmpty else { return }

        var known = Dictionary(
            (try? context.fetch(FetchDescriptor<SyncMarkRecord>()))?.map { ($0.recordName, $0) }
                ?? [],
            uniquingKeysWith: { first, _ in first }
        )

        for record in records {
            guard let touched = record.date(Field.modifiedAt) else { continue }
            if let existing = known[record.name] {
                existing.update(to: touched)
            } else {
                let mark = SyncMarkRecord(recordName: record.name, syncedModifiedAt: touched)
                context.insert(mark)
                // Kept so a repeated name updates this row, not a second insert.
                known[record.name] = mark
            }
        }
    }

    /// Convenience for a whole record.
    @MainActor
    public static func markSynced(_ record: SyncedRecord, in context: ModelContext) {
        guard let touched = record.date(Field.modifiedAt) else { return }
        markSynced(name: record.name, modifiedAt: touched, in: context)
    }
}
