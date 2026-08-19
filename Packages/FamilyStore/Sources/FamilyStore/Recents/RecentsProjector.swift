import Foundation
import PolicyEngine
import SwiftData

/// Unlike `EventLog`, this is awaited — a dropped row here freezes a live screen.
@ModelActor
public actor RecentsProjector {
    /// Bounded so an upgrade can't hang — a short trail is fine, a wrong one isn't.
    public static let rebuildLimit = RecentTrail.cap * 8

    /// About the log, not the trail — `.task` can fire twice on some transitions.
    public static let coalescingWindow: TimeInterval = 2

    public enum Failure: Error, Equatable {
        case unknownKid(UUID)
    }

    /// Returns the trail itself, so no caller can race its own write with a fetch.
    @discardableResult
    public func record(_ visit: VisitEvent, for kidID: UUID) throws -> [RecentEntry] {
        let kid = try kid(kidID)

        if RecentTrailProjection.isStale(kid) {
            try RecentTrailProjection.rebuild(for: kid, in: modelContext)
        }

        // Event row skipped on repeat; recompute still runs, so this is total.
        if !isRepeat(visit, for: kid) {
            let record = VisitEventRecord(event: visit)
            modelContext.insert(record)
            kid.attach(record)
        }

        try RecentTrailProjection.recompute(for: kid, in: modelContext)
        try modelContext.save()
        return RecentTrailProjection.trail(of: kid)
    }

    /// Recomputed always — a device found that trusted rows can silently go stale.
    public func trail(for kidID: UUID) throws -> [RecentEntry] {
        let kid = try kid(kidID)
        try RecentTrailProjection.recompute(for: kid, in: modelContext)
        try modelContext.save()
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

    /// The retention sweep's floor — sweeping past it silently breaks the shelf.
    public func retentionFloor(for kidID: UUID) throws -> Date? {
        try RecentTrailProjection.trail(of: kid(kidID)).map(\.at).min()
    }

    // MARK: -

    /// A range, not a ceiling — an untrusted clock must never cost a lost visit.
    private func isRepeat(_ visit: VisitEvent, for kid: Kid) -> Bool {
        guard
            let newest = kid.visits.compactMap(\.event).max(by: { $0.at < $1.at }),
            newest.itemID == visit.itemID
        else { return false }
        return (0..<Self.coalescingWindow).contains(visit.at.timeIntervalSince(newest.at))
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
