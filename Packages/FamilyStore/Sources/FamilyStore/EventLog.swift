import Foundation
import SwiftData

/// A dropped log line is acceptable; a stalled player is not — ``log(_:for:)``
/// swallows failures. ``record(_:for:)`` is awaited, for tests only; never
/// call it from the playback path. Contrast policy writes: always awaited,
/// failures surfaced — the opposite contract, for the opposite reason.
@ModelActor
public actor EventLog {
    /// A mis-tap, not a listen — applied here so no caller can forget it.
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

    /// Discards a short play silently — a filter, not a failure.
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
