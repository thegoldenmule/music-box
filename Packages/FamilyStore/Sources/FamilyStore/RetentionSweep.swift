import Foundation
import PolicyEngine
import SwiftData

/// Which week a moment belongs to.
///
/// **UTC, Monday-first, and not the device's calendar.** `weekStart` is half the
/// natural key of a ``WeeklySummaryRecord``, so two devices in two time zones must
/// agree on it or they write two records for one week. Same argument as the segment
/// day, and the same reason it does not use `Calendar.current`.
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

/// How far back a sweep may reach, and why not further.
///
/// **Pure, because every clause is a way to lose a child's history.**
public enum RetentionCutoff {
    /// The window. Events older than this are rolled into a summary and deleted.
    ///
    /// **A parent deleting whenever they like is a different mechanism** and is
    /// unaffected: that is ``Kid/deleteHistory(at:issuedBy:)``, which is unbounded and
    /// immediate. This is only the automatic floor.
    public static let days = 90

    /// The instant a sweep may reach up to, or `nil` when it may not run.
    ///
    /// - `now - days` is the window.
    /// - **Clamped to the trail's floor.** Sweeping through the oldest visit the live
    ///   Recent shelf still references leaves a trail that cannot be rebuilt, so the
    ///   next bump of `RecentTrail.version` silently empties every kid's shelf —
    ///   months later, on an upgrade, with nothing on screen to explain it. Costs at
    ///   most a shelf's worth of rows past the window.
    /// - **Rounded down to a week boundary**, because a week is the unit that gets
    ///   summarised and half a week rolled up is a summary that disagrees with its
    ///   own label.
    public static func boundary(now: Date, trailFloor: Date?) -> Date {
        let window = now.addingTimeInterval(-Double(days) * 86_400)
        let clamped = trailFloor.map { min(window, $0) } ?? window
        return RetentionWeek.start(of: clamped)
    }

    /// Whether a week is entirely old enough.
    ///
    /// Whole weeks only. A week straddling the boundary still holds rows a parent
    /// would call recent, and summarising it now means summarising it again later.
    public static func isSweepable(weekStart: Date, boundary: Date) -> Bool {
        RetentionWeek.end(of: weekStart) <= boundary
    }
}

// MARK: -

/// Rolls events older than the window into weekly summaries, then deletes them.
///
/// **Two phases in this order, which is the whole safety story.** The summary for a
/// week is written and *saved* before any row it covers is deleted, and the deleting
/// pass re-reads the summary rather than trusting that it just wrote one. A crash
/// between the two leaves both present, which the next pass resolves; the other
/// order leaves a hole nothing can fill.
///
/// **No owner and no lease — an idempotence story instead.** The spec asked for a
/// single named owner *or* an idempotence story, on the grounds that a bulk mutation
/// with neither is a sync design question rather than a retention one. This takes the
/// second: the record name is `(kid, weekStart)`, and ``WeeklySummary`` has a total
/// order on every list and encodes with sorted keys, so two devices summarising one
/// week write identical bytes under one key and the server has nothing to arbitrate.
/// Cheaper than a lease table, and there is no distributed lock to get wrong.
///
/// **The residual, stated plainly:** two devices that have not converged could
/// summarise a week from different event sets and produce different bytes, and
/// last-write-wins picks one. Only whole weeks at least ``RetentionCutoff/days`` old
/// are swept, so segments have had that long to propagate — unlikely rather than
/// impossible. Closing it properly means a mergeable payload, which is a larger
/// change than a lease would have been.
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

    /// Weeks holding sweepable rows, oldest first.
    ///
    /// **Only rows that have left the device count.** A row with no `exportedAt` has
    /// not been carried anywhere, so deleting it loses it for every other device
    /// permanently — the summary would survive here and the co-parent's copy of the
    /// row would never have existed. A week whose rows are all unexported is not
    /// ready, and the next pass finds it once the segment has gone out.
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

    /// Writes or updates one week's summary.
    ///
    /// Built from the same ``WeeklySummary/of(_:previouslyHeard:)`` a parent's report
    /// uses, so the persisted form and the derived one cannot drift into two answers.
    ///
    /// `previouslyHeard` is `nil`, which makes `firstTimeHeard` empty. That is the
    /// documented contract for a caller that cannot answer it — and this one cannot,
    /// because knowing what came before means reading a window that may itself have
    /// been swept. An empty list is honest; a wrong one would claim a child had never
    /// heard a song they have played for a year.
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
            // **No `deniedBy`.** That is the entry as it stands *today*, which is a
            // fact about the current policy rather than about the week — and it must
            // not be frozen into a record that outlives the rule. A reader of an old
            // summary gets the stored reason and no claim about a rule that may since
            // have gone.
            return ReviewedBlock(event: event)
        }

        // Built here rather than through `ReviewReader`, which is an actor over a
        // container and would mean a second fetch of rows already in hand.
        let window = ReviewWindow(
            kidID: kid.id,
            interval: DateInterval(start: weekStart, end: end),
            plays: plays,
            searches: kid.searches.filter { inWeek($0.at) }.map(\.event),
            blocks: blocks,
            visits: visits,
            unreadable: unreadable,
            // `builtAt` is the week's own end, not the wall clock: it belongs to what
            // the payload describes, and a clock would make two devices' bytes differ.
            builtAt: end,
            // Complete by construction — these are the raw rows for the week, read
            // immediately before they are deleted. The `summarisedBefore` a *reader*
            // sees afterwards is `ReviewReader`'s to report, not this payload's claim
            // about itself.
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

    /// Deletes one week's exported rows, **only if its summary is on disk.**
    ///
    /// Re-read rather than assumed, and that is what the two phases are for: on a
    /// device that did not write the summary itself, its presence is how the
    /// household says the week has been preserved. Absent, nothing is deleted and the
    /// next pass tries again.
    ///
    /// `RecentTrailRecord` is untouched — exempt from the sweep and not from
    /// `deleteHistory` — and the floor in ``RetentionCutoff`` is what keeps it
    /// rebuildable. Favorites and playlists are not events and are never in scope.
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
