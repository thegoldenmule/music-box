import Foundation
import PolicyEngine
import SwiftData

/// UTC Monday-first, never `Calendar.current` — two devices must agree on the key.
public enum RetentionWeek {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2  // Monday
        return calendar
    }

    /// Midnight UTC on the Monday of the week containing `date`.
    public static func start(of date: Date) -> Date {
        let calendar = self.calendar
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: parts) ?? date
    }

    /// The instant the week beginning at `start` ends — exclusive.
    public static func end(of start: Date) -> Date {
        calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(604_800)
    }
}

// MARK: -

/// How far a sweep may reach — pure, since every clause risks losing history.
public enum RetentionCutoff {
    /// Events past this are summarised and deleted; `Kid.deleteHistory` is separate.
    public static let days = 90

    // Clamped to the trail's floor — sweeping past the oldest visit a live
    // shelf references leaves a trail no rebuild can recover, silently empty
    // on the next `RecentTrail.version` bump. Rounded to a week boundary, the
    // summarised unit — half a week disagrees with its own label.
    public static func boundary(now: Date, trailFloor: Date?) -> Date {
        let window = now.addingTimeInterval(-Double(days) * 86_400)
        let clamped = trailFloor.map { min(window, $0) } ?? window
        return RetentionWeek.start(of: clamped)
    }

    /// Whole weeks only — a straddling week would need summarising again later.
    public static func isSweepable(weekStart: Date, boundary: Date) -> Bool {
        RetentionWeek.end(of: weekStart) <= boundary
    }
}

// MARK: -

// Rolls events older than the window into weekly summaries, then deletes.
//
// Order is the safety story: the summary is saved before its rows are
// deleted, and deletion re-reads it rather than trusting it just wrote one —
// a crash leaves both present rather than a hole nothing can fill.
//
// No owner or lease — idempotence instead. `(kid, weekStart)` names the
// record, and sorted-key encoding means two devices summarising one week
// write identical bytes, so the server has nothing to arbitrate.
//
// Residual: two unconverged devices could summarise different event sets and
// last-write-wins picks one — unlikely, since only weeks past
// `RetentionCutoff.days` sweep, giving segments time to propagate.
public enum RetentionSweep {
    /// Summarises and then deletes, for one kid. Returns rows deleted.
    @MainActor
    @discardableResult
    public static func run(
        for kidID: UUID,
        in context: ModelContext,
        trailFloor: Date?,
        now: Date = .now
    ) -> Int {
        guard let kid = kid(kidID, in: context) else { return 0 }
        let boundary = RetentionCutoff.boundary(now: now, trailFloor: trailFloor)

        let weeks = sweepableWeeks(for: kid, boundary: boundary)
        guard !weeks.isEmpty else { return 0 }

        for week in weeks { summarise(week, for: kid, in: context) }
        guard (try? context.save()) != nil else { return 0 }

        var deleted = 0
        for week in weeks { deleted += purge(week, for: kid, in: context) }
        guard (try? context.save()) != nil else { return 0 }
        return deleted
    }

    // MARK: - Which weeks

    /// Only exported rows count — deleting an unexported one loses it everywhere.
    @MainActor
    private static func sweepableWeeks(for kid: Kid, boundary: Date) -> [Date] {
        var weeks = Set<Date>()
        for row in exportedRows(for: kid) where row.at < boundary {
            let week = RetentionWeek.start(of: row.at)
            if RetentionCutoff.isSweepable(weekStart: week, boundary: boundary) {
                weeks.insert(week)
            }
        }
        return weeks.sorted()
    }

    @MainActor
    private static func exportedRows(for kid: Kid) -> [any ExportableEvent] {
        var rows: [any ExportableEvent] = []
        rows.append(contentsOf: kid.visits as [any ExportableEvent])
        rows.append(contentsOf: kid.searches as [any ExportableEvent])
        rows.append(contentsOf: kid.plays as [any ExportableEvent])
        rows.append(contentsOf: kid.blocks as [any ExportableEvent])
        return rows.filter { $0.exportedAt != nil }
    }

    // MARK: - Phase one

    /// `previouslyHeard: nil` — an honest empty list, not a false "never heard" claim.
    @MainActor
    private static func summarise(_ weekStart: Date, for kid: Kid, in context: ModelContext) {
        let end = RetentionWeek.end(of: weekStart)
        func inWeek(_ at: Date) -> Bool { at >= weekStart && at < end }

        var unreadable = 0

        let plays = kid.plays.filter { inWeek($0.at) }.compactMap { row -> PlayEvent? in
            guard let event = row.event else {
                unreadable += 1
                return nil
            }
            return event
        }
        let visits = kid.visits.filter { inWeek($0.at) }.compactMap { row -> VisitEvent? in
            guard let event = row.event else {
                unreadable += 1
                return nil
            }
            return event
        }
        let blocks = kid.blocks.filter { inWeek($0.at) }.compactMap { row -> ReviewedBlock? in
            guard let event = row.event else {
                unreadable += 1
                return nil
            }
            // No `deniedBy` — today's rule must not freeze into a record that outlives it.
            return ReviewedBlock(event: event)
        }

        // Built here, not via `ReviewReader` — that actor would refetch rows in hand.
        let window = ReviewWindow(
            kidID: kid.id,
            interval: DateInterval(start: weekStart, end: end),
            plays: plays,
            searches: kid.searches.filter { inWeek($0.at) }.map(\.event),
            blocks: blocks,
            visits: visits,
            unreadable: unreadable,
            // Week's own end, not wall clock — a clock would make devices' bytes differ.
            builtAt: end,
            // Complete by construction: raw rows read right before deletion.
            coverage: .complete
        )
        let summary = WeeklySummary.of(window, previouslyHeard: nil)

        guard let payload = try? WeeklySummary.encoder().encode(summary) else { return }

        if let existing = kid.summaries.first(where: { $0.weekStart == weekStart }) {
            existing.replace(payload: payload)
        } else {
            let record = WeeklySummaryRecord(weekStart: weekStart, payload: payload)
            context.insert(record)
            kid.attach(record)
        }
    }

    // MARK: - Phase two

    /// Deletes a week's rows only if its summary is on disk — re-read, not assumed.
    @MainActor
    private static func purge(_ weekStart: Date, for kid: Kid, in context: ModelContext) -> Int {
        guard kid.summaries.contains(where: { $0.weekStart == weekStart && !$0.payload.isEmpty })
        else { return 0 }

        let end = RetentionWeek.end(of: weekStart)
        let doomed = exportedRows(for: kid).filter { $0.at >= weekStart && $0.at < end }
        var deleted = 0
        for row in doomed {
            guard let model = row as? any PersistentModel else { continue }
            context.delete(model)
            deleted += 1
        }
        return deleted
    }

    @MainActor
    private static func kid(_ id: UUID, in context: ModelContext) -> Kid? {
        var descriptor = FetchDescriptor<Kid>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
