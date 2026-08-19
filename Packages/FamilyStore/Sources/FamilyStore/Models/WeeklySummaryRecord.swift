import Foundation
import SwiftData

/// Empty at v1 on purpose: the sweep that fills this must not also introduce it.
@Model
public final class WeeklySummaryRecord {
    public private(set) var id: UUID = UUID()

    /// Start of the week this covers. Device time, so approximate.
    public private(set) var weekStart: Date = Date.distantPast

    /// Was the one record without this; free to add since nothing writes here yet.
    public private(set) var modifiedAt: Date = Date.distantPast

    // Held outside the row: an unbounded blob against a 1 MB `CKRecord` ceiling.
    // The failure this prevents is the worst-shaped one here — a heavy week's
    // blob exceeds the ceiling, the local save succeeds, export fails quietly,
    // and the sweep has already deleted the raw rows in the same operation.
    // Free right now only because nothing writes this table yet, so there is
    // no stored blob to move; that stops being true the moment the sweep ships.
    @Attribute(.externalStorage)
    public private(set) var payload: Data = Data()

    public var kid: Kid?

    public init(id: UUID = UUID(), weekStart: Date, payload: Data, at: Date = .now) {
        self.id = id
        self.weekStart = weekStart
        self.payload = payload
        self.modifiedAt = at
    }

    /// No-op when unchanged — re-summarising every pass would flood the outbox.
    public func replace(payload newPayload: Data, at: Date = .now) {
        guard newPayload != payload else { return }
        payload = newPayload
        modifiedAt = at
    }
}
