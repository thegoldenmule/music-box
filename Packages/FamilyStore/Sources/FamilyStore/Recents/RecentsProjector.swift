import Foundation
import PolicyEngine
import SwiftData

/// Writes visits and maintains the shelf they produce, in one save.
///
/// **Not ``EventLog``, and the difference is the contract rather than the
/// mechanics.** That actor exists to be dumb: a dropped log line costs a report
/// a line, so it swallows failures and returns before the write lands, and
/// nothing that a kid can see ever reads from it. Every clause of that becomes
/// false for a projection. A failed projection write inside `EventLog` would be
/// eaten by its `try?` — losing the event *and* the shelf update, silently —
/// and what it feeds is a screen the kid is looking at with their finger still
/// on the tile. A dropped row there is the home screen not moving when they
/// pressed play, which reads as the tap having done nothing.
///
/// So this one is awaited, its failures reach the caller, and **there is
/// deliberately no fire-and-forget overload.** Two detached writes have no
/// ordering guarantee between them, and the order visits arrive in is the entire
/// content of a trail.
///
/// The event row and the trail land in one ``ModelContext`` save, so there is no
/// state in which the log and its read model disagree.
@ModelActor
public actor RecentsProjector {
    /// How far back a rebuild replays.
    ///
    /// Bounded so a long history cannot make an upgrade hang. A kid whose last
    /// few hundred visits hold fewer than ``RecentTrail/cap`` distinct entries
    /// gets a **shorter** trail, never a wrong one — the same one-way error
    /// ``ReviewReader/previouslyHeard(for:before:limit:)`` accepts, for the same
    /// reason.
    public static let rebuildLimit = RecentTrail.cap * 8

    /// Below this, a repeat visit is the same arrival and writes no event row.
    ///
    /// The trail is idempotent either way — the walk collapses duplicates — so
    /// this is about the *log*, which a parent reads and which should not claim
    /// a kid opened one album eleven times in four seconds. `.task` fires twice
    /// on some navigation transitions, and a screen reappearing under a
    /// dismissed sheet is not a second visit.
    ///
    /// Compared between two supplied timestamps, never against a hidden clock.
    public static let coalescingWindow: TimeInterval = 2

    public enum Failure: Error, Equatable {
        case unknownKid(UUID)
    }

    /// Appends the visit, folds it into the trail, and **returns the trail it
    /// produced** — newest first.
    ///
    /// Returning the read is the whole reason this is awaited. A caller that
    /// writes and then fetches is racing its own write, which is precisely the
    /// bug the Recent shelf has today: the home screen reloads microseconds
    /// after the write is handed to a detached task, so the fetch usually runs
    /// before the row commits. Here there is no second read to lose the race.
    @discardableResult
    public func record(_ visit: VisitEvent, for kidID: UUID) throws -> [RecentEntry] {
        let kid = try kid(kidID)

        if RecentTrailProjection.isStale(kid) {
            try RecentTrailProjection.rebuild(for: kid, in: modelContext)
        }

        // The event row is skipped for a repeat inside the window; the recompute
        // still runs, so this method is total — every caller gets the current
        // shelf back, always.
        if !isRepeat(visit, for: kid) {
            let record = VisitEventRecord(event: visit)
            modelContext.insert(record)
            kid.attach(record)
        }

        try RecentTrailProjection.recompute(for: kid, in: modelContext)
        try modelContext.save()
        return RecentTrailProjection.trail(of: kid)
    }

    /// The stored trail, newest first, rebuilding first if the walk has changed.
    ///
    /// What a session reads at launch and on a kid switch.
    public func trail(for kidID: UUID) throws -> [RecentEntry] {
        let kid = try kid(kidID)
        if RecentTrailProjection.isStale(kid) {
            try RecentTrailProjection.rebuild(for: kid, in: modelContext)
            try modelContext.save()
        }
        return RecentTrailProjection.trail(of: kid)
    }

    /// Throws the trail away and replays the visits behind it.
    @discardableResult
    public func rebuild(for kidID: UUID) throws -> [RecentEntry] {
        let kid = try kid(kidID)
        try RecentTrailProjection.rebuild(for: kid, in: modelContext)
        try modelContext.save()
        return RecentTrailProjection.trail(of: kid)
    }

    /// The oldest visit the live trail still depends on.
    ///
    /// **The retention sweep's floor.** A sweep that deletes below this stays
    /// rebuildable; one that does not silently shortens every kid's shelf the
    /// next time ``RecentTrail/version`` moves — months later, on an upgrade,
    /// with nothing on screen to explain it. Costs at most ``RecentTrail/cap``
    /// rows per kid past the window, which is nothing, and it is what makes
    /// "a projection is rebuildable by replaying its events" true rather than
    /// aspirational.
    ///
    /// `nil` when the trail is empty and the sweep may take everything.
    public func retentionFloor(for kidID: UUID) throws -> Date? {
        try RecentTrailProjection.trail(of: kid(kidID)).map(\.at).min()
    }

    // MARK: -

    /// Whether this is the same arrival as the newest visit already recorded.
    private func isRepeat(_ visit: VisitEvent, for kid: Kid) -> Bool {
        guard
            let newest = kid.visits.compactMap(\.event).max(by: { $0.at < $1.at }),
            newest.itemID == visit.itemID
        else { return false }
        return visit.at.timeIntervalSince(newest.at) < Self.coalescingWindow
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
