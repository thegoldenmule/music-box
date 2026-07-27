import Foundation
import SwiftData

/// Writes activity events off the caller's thread.
///
/// **A dropped log line is acceptable; a stalled player is not.** The intended
/// entry points are the ``log(_:for:)`` overloads, which return immediately and
/// swallow failures. Nothing that decides what a kid may see or play ever reads
/// from here, so losing a row costs a report a line and costs safety nothing.
///
/// The awaited ``record(_:for:)`` overloads exist for tests and for any surface
/// that genuinely needs to know the write landed. Do not call them from the
/// playback path.
///
/// This is the one writer in v1: the active kid's session. The admin writes
/// policy entries on the main context, and those writes are awaited with their
/// failures surfaced — the opposite contract, for the opposite reason.
@ModelActor
public actor EventLog {
    /// Below this, a play is a mis-tap rather than a listen and is never
    /// written. Applied here rather than at the call site so no caller can
    /// forget it.
    public static let minimumPlaySeconds = 5

    public enum Failure: Error, Equatable {
        /// No kid with that identifier in this store.
        case unknownKid(UUID)
    }

    // MARK: - Fire and forget

    public nonisolated func log(_ event: SearchEvent, for kidID: UUID) {
        Task { try? await record(event, for: kidID) }
    }

    public nonisolated func log(_ event: PlayEvent, for kidID: UUID) {
        Task { try? await record(event, for: kidID) }
    }

    public nonisolated func log(_ event: BlockEvent, for kidID: UUID) {
        Task { try? await record(event, for: kidID) }
    }

    // MARK: - Awaited

    public func record(_ event: SearchEvent, for kidID: UUID) throws {
        let kid = try kid(kidID)
        let record = SearchEventRecord(event: event)
        modelContext.insert(record)
        kid.attach(record)
        try modelContext.save()
    }

    /// Discards a play shorter than ``minimumPlaySeconds`` without complaint —
    /// that is a filter, not a failure.
    public func record(_ event: PlayEvent, for kidID: UUID) throws {
        guard event.secondsPlayed >= Self.minimumPlaySeconds else { return }
        let kid = try kid(kidID)
        let record = PlayEventRecord(event: event)
        modelContext.insert(record)
        kid.attach(record)
        try modelContext.save()
    }

    public func record(_ event: BlockEvent, for kidID: UUID) throws {
        let kid = try kid(kidID)
        let record = BlockEventRecord(event: event)
        modelContext.insert(record)
        kid.attach(record)
        try modelContext.save()
    }

    // MARK: -

    private func kid(_ id: UUID) throws -> Kid {
        var descriptor = FetchDescriptor<Kid>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let kid = try modelContext.fetch(descriptor).first else {
            throw Failure.unknownKid(id)
        }
        return kid
    }
}
