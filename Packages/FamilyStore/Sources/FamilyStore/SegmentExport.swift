import Foundation
import SwiftData

/// Batched, not per-row — a backlog of searches can't queue behind an urgent
/// deny with no CloudKit reorder API.
/// Keyed `(kid, device, day, table, index)`: two devices never collide, so the
/// volume leader in this store has no conflict surface at all.
/// Never on the playback path — heavier than a log line, so it runs only from
/// the sync pass, never from logging.
public enum SegmentExport {
    /// Bounded so `index` makes a day a resumable sequence, not all-or-nothing.
    public static let rowsPerSegment = 250

    // MARK: - Packing

    /// Stamps `exportedAt` only after saving — the other order can lose history.
    @MainActor
    @discardableResult
    public static func pack(
        for kids: [UUID],
        deviceID: UUID,
        in context: ModelContext,
        at now: Date = .now
    ) -> Int {
        var written = 0
        for kidID in kids {
            for table in ActivityTable.allCases {
                written += pack(kidID: kidID, table: table, deviceID: deviceID, in: context, at: now)
            }
        }
        return written
    }

    @MainActor
    private static func pack(
        kidID: UUID,
        table: ActivityTable,
        deviceID: UUID,
        in context: ModelContext,
        at now: Date
    ) -> Int {
        let pending = unexported(table, kidID: kidID, in: context)
        guard !pending.isEmpty else { return 0 }

        // Grouped by UTC day — two zones must agree which day a row belongs to.
        let byDay = Dictionary(grouping: pending) { Self.dayUTC($0.at) }

        var written = 0
        for day in byDay.keys.sorted() {
            // Oldest first, so a partial export is a prefix of the day, not a scatter.
            let rows = (byDay[day] ?? []).sorted { $0.at < $1.at }
            let base = nextIndex(kidID: kidID, deviceID: deviceID, day: day, table: table, in: context)

            for (offset, chunk) in rows.chunked(into: rowsPerSegment).enumerated() {
                guard let payload = encode(chunk, table: table) else { continue }
                context.insert(
                    ActivitySegmentRecord(
                        kidID: kidID,
                        deviceID: deviceID,
                        dayUTC: day,
                        table: table.rawValue,
                        index: base + offset,
                        payload: payload,
                        at: now
                    )
                )
                guard (try? context.save()) != nil else { continue }
                // Only after the save — see `pack(for:deviceID:in:at:)`.
                for row in chunk { row.markExported(at: now) }
                try? context.save()
                written += 1
            }
        }
        return written
    }

    private static func encode(_ rows: [any ExportableEvent], table: ActivityTable) -> Data? {
        let payload = ActivitySegment(
            rows: rows.compactMap { row in
                switch table {
                case .visits:
                    (row as? VisitEventRecord)?.event.map {
                        ActivitySegment.Row(id: row.id, visit: $0)
                    }
                case .searches:
                    (row as? SearchEventRecord).map {
                        ActivitySegment.Row(id: row.id, search: $0.event)
                    }
                case .plays:
                    (row as? PlayEventRecord)?.event.map {
                        ActivitySegment.Row(id: row.id, play: $0)
                    }
                case .blocks:
                    (row as? BlockEventRecord)?.event.map {
                        ActivitySegment.Row(id: row.id, block: $0)
                    }
                }
            }
        )
        // Unreadable rows skip export, not marked — retried by a later build.
        guard !payload.rows.isEmpty else { return nil }
        return try? JSONEncoder().encode(payload)
    }

    // MARK: - Unpacking

    /// Idempotent by row id, not bookkeeping — no `absorbedAt` column needed.
    @MainActor
    @discardableResult
    public static func unpack(
        for kids: [UUID],
        deviceID: UUID,
        in context: ModelContext
    ) -> Int {
        let segments = ((try? context.fetch(FetchDescriptor<ActivitySegmentRecord>())) ?? [])
            // Our own segments are already rows — absorbing them would self-duplicate.
            .filter { $0.deviceID != deviceID }
            .filter { $0.kidID.map(kids.contains) ?? false }
        guard !segments.isEmpty else { return 0 }

        let known = knownEventIDs(in: context)

        // Not optional — a late device could resurrect history on another phone.
        let clears = (try? context.fetch(FetchDescriptor<HistoryClearRecord>())) ?? []
        var boundaries: [UUID: Date] = [:]
        for kidID in kids {
            if let boundary = HistoryClears.boundary(for: kidID, in: clears) {
                boundaries[kidID] = boundary
            }
        }

        var inserted = 0

        for segment in segments {
            guard let kidID = segment.kidID,
                let kid = kid(kidID, in: context),
                let table = ActivityTable(rawValue: segment.table),
                let payload = try? JSONDecoder().decode(ActivitySegment.self, from: segment.payload)
            else { continue }

            // Skipped, never dropped — a later build here will read this version.
            guard payload.version <= ActivitySegment.version else { continue }

            let boundary = boundaries[kidID]
            for row in payload.rows
            where !known.contains(row.id) && !isCleared(row, table: table, by: boundary) {
                guard materialise(row, table: table, for: kid, from: segment, in: context) else {
                    continue
                }
                inserted += 1
            }
        }

        if inserted > 0 { try? context.save() }
        return inserted
    }

    /// A row with no timestamp is never cleared — fails toward keeping history.
    private static func isCleared(
        _ row: ActivitySegment.Row, table: ActivityTable, by boundary: Date?
    ) -> Bool {
        guard let boundary else { return false }
        let at: Date? =
            switch table {
            case .visits: row.visit?.at
            case .searches: row.search?.at
            case .plays: row.play?.at
            case .blocks: row.block?.at
            }
        guard let at else { return false }
        return at <= boundary
    }

    /// Attributed to the segment's writer, not this device — else the column lies.
    @MainActor
    private static func materialise(
        _ row: ActivitySegment.Row,
        table: ActivityTable,
        for kid: Kid,
        from segment: ActivitySegmentRecord,
        in context: ModelContext
    ) -> Bool {
        let origin = segment.deviceID
        switch table {
        case .visits:
            guard let event = row.visit else { return false }
            let record = VisitEventRecord(id: row.id, event: event, originatingDeviceID: origin)
            context.insert(record)
            kid.attach(record)
        case .searches:
            guard let event = row.search else { return false }
            let record = SearchEventRecord(id: row.id, event: event, originatingDeviceID: origin)
            context.insert(record)
            kid.attach(record)
        case .plays:
            guard let event = row.play else { return false }
            let record = PlayEventRecord(id: row.id, event: event, originatingDeviceID: origin)
            context.insert(record)
            kid.attach(record)
        case .blocks:
            guard let event = row.block else { return false }
            let record = BlockEventRecord(id: row.id, event: event, originatingDeviceID: origin)
            context.insert(record)
            kid.attach(record)
        }
        // Already left a device, so the retention sweep may safely delete these.
        return true
    }

    // MARK: -

    /// One pass, not a lookup per row — absorbing a week is thousands of rows.
    @MainActor
    private static func knownEventIDs(in context: ModelContext) -> Set<UUID> {
        var ids = Set<UUID>()
        ids.formUnion(((try? context.fetch(FetchDescriptor<VisitEventRecord>())) ?? []).map(\.id))
        ids.formUnion(((try? context.fetch(FetchDescriptor<SearchEventRecord>())) ?? []).map(\.id))
        ids.formUnion(((try? context.fetch(FetchDescriptor<PlayEventRecord>())) ?? []).map(\.id))
        ids.formUnion(((try? context.fetch(FetchDescriptor<BlockEventRecord>())) ?? []).map(\.id))
        return ids
    }

    @MainActor
    private static func unexported(
        _ table: ActivityTable, kidID: UUID, in context: ModelContext
    ) -> [any ExportableEvent] {
        func rows<T: PersistentModel & ExportableEvent & KidScoped>(_: T.Type) -> [any
            ExportableEvent]
        {
            ((try? context.fetch(FetchDescriptor<T>())) ?? [])
                .filter { $0.exportedAt == nil && $0.kid?.id == kidID }
        }
        switch table {
        case .visits: return rows(VisitEventRecord.self)
        case .searches: return rows(SearchEventRecord.self)
        case .plays: return rows(PlayEventRecord.self)
        case .blocks: return rows(BlockEventRecord.self)
        }
    }

    /// Resumes, never restarts — a segment is never overwritten under the same key.
    @MainActor
    private static func nextIndex(
        kidID: UUID, deviceID: UUID, day: String, table: ActivityTable, in context: ModelContext
    ) -> Int {
        let mine = ((try? context.fetch(FetchDescriptor<ActivitySegmentRecord>())) ?? [])
            .filter {
                $0.kidID == kidID && $0.deviceID == deviceID && $0.dayUTC == day
                    && $0.table == table.rawValue
            }
        return (mine.map(\.index).max() ?? -1) + 1
    }

    @MainActor
    private static func kid(_ id: UUID, in context: ModelContext) -> Kid? {
        var descriptor = FetchDescriptor<Kid>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// `yyyy-MM-dd` UTC — part of the record key, so it can't depend on locale.
    static func dayUTC(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
