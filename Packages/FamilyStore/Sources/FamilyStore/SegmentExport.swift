import Foundation
import SwiftData

/// Packing a kid's events into segments, and unpacking somebody else's.
///
/// **The four event tables are in `neverSyncs` and this is why that is not a
/// gap.** They never travel as rows: one record each would put a parent's deny
/// behind a backlog of a child's blocked search results, and there is no API to
/// reorder a pending CloudKit queue. They travel batched, keyed
/// `(kid, device, day, table, index)`.
///
/// **That key is the design.** Two devices never write the same segment, so the
/// volume leader in this store has no conflict surface at all — not "rarely
/// conflicts", none, by construction. It is only as good as `deviceID` is stable:
/// a Keychain identity that churns re-keys future segments and can re-export a
/// device's history under a new key. That is a duplicate, not a loss, and the
/// absorbing side drops it because the row identifiers are already present.
///
/// **Never on the playback path.** Packing walks four tables and encodes; the
/// caller runs it from the sync pass, never from logging. A dropped log line is
/// acceptable and a stalled player is not, and this is heavier than a log line.
public enum SegmentExport {
    /// How many rows go in one segment.
    ///
    /// Bounded rather than unbounded even though the payload is
    /// `@Attribute(.externalStorage)`: `index` exists so that a day is a sequence
    /// rather than one object, which is what makes an interrupted export resumable
    /// instead of all-or-nothing.
    public static let rowsPerSegment = 250

    // MARK: - Packing

    /// Packs everything this device has not exported yet for these kids.
    ///
    /// Returns how many segments were written. **A row is stamped `exportedAt`
    /// only after the segment holding it is saved**, so an interruption leaves it
    /// looking unexported and it goes in the next segment. The other order loses a
    /// child's history with everything reporting success.
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

        // **Grouped by UTC day, not by the device's calendar.** The day is part of
        // the record key, so two devices in two time zones must agree on which day
        // a row belongs to or they would write different keys for the same events.
        let byDay = Dictionary(grouping: pending) { Self.dayUTC($0.at) }

        var written = 0
        for day in byDay.keys.sorted() {
            // Oldest first within a day, so `index` runs in the order the events
            // happened and a partial export is a prefix of the day rather than a
            // scatter through it.
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
                // Only now. See the note on `pack(for:deviceID:in:at:)`.
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
        // A row whose own columns do not read back is skipped rather than faked, and
        // deliberately **not** stamped exported — it stays for a build that can read
        // it. An empty payload is not worth a record.
        guard !payload.rows.isEmpty else { return nil }
        return try? JSONEncoder().encode(payload)
    }

    // MARK: - Unpacking

    /// Materialises the events in segments this device did not write.
    ///
    /// Returns how many event rows were created.
    ///
    /// **Idempotent by row identity rather than by bookkeeping.** Each payload row
    /// carries the identifier of the record it came from, so absorbing checks what
    /// is already present and inserts the rest. That is why there is no
    /// `absorbedAt` column and no device-local set of segment ids growing without
    /// bound — and it is also what makes a re-export under a churned `deviceID`
    /// harmless.
    @MainActor
    @discardableResult
    public static func unpack(
        for kids: [UUID],
        deviceID: UUID,
        in context: ModelContext
    ) -> Int {
        let segments = ((try? context.fetch(FetchDescriptor<ActivitySegmentRecord>())) ?? [])
            // Our own are already rows here; absorbing them would duplicate a
            // device's history against itself.
            .filter { $0.deviceID != deviceID }
            .filter { $0.kidID.map(kids.contains) ?? false }
        guard !segments.isEmpty else { return 0 }

        let known = knownEventIDs(in: context)

        // **The interlock with clearing, and it is not optional.** A clear is a
        // statement about a range, so it reaches rows that had not arrived when it
        // was issued — which is precisely a segment written by a device that had not
        // heard about it yet. Without this, absorbing resurrects the history a
        // parent was told had been deleted, and it comes back on the *other*
        // parent's phone where nobody is looking. See ``HistoryClears``.
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

            // **A version we do not know is skipped, never dropped.** The device
            // that wrote it still has the rows, and a later build here will read
            // it. Deleting it would lose a child's history to a version check.
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

    /// Whether a clear already destroyed this row's moment.
    ///
    /// `at <= boundary`, the same inclusive comparison `HistoryClearApplier` makes on
    /// the rows it deletes, so a row is not resurrected by arriving a second later
    /// than the one beside it.
    ///
    /// A row that cannot say when it happened is **not** treated as cleared: the
    /// direction that fails safely here is keeping a row the parent may not have
    /// meant to keep, rather than silently discarding a child's history because a
    /// payload field did not read back.
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

    /// Inserts one row, attributed to the device that originally wrote it.
    ///
    /// `originatingDeviceID` comes from the segment rather than from this device —
    /// it is the cheapest forensic column available and it would be worthless if
    /// absorbing rewrote it to whoever happened to import the row.
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
        // Absorbed rows arrived from somewhere, so they have already left a device
        // and the retention sweep may delete them without losing them.
        return true
    }

    // MARK: -

    /// Every event identifier already on this device, across the four tables.
    ///
    /// One pass rather than a lookup per row: absorbing a week of one child's
    /// listening is thousands of rows, and a fetch each would be thousands of
    /// queries.
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

    /// Where this device's next segment for a day goes.
    ///
    /// Resumes rather than restarting: a device that exported half a day yesterday
    /// continues the sequence, so an existing segment is never overwritten by one
    /// holding different rows under the same key.
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

    /// `yyyy-MM-dd` in UTC. Part of the record key, so it must not depend on the
    /// device's locale, calendar or time zone.
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
