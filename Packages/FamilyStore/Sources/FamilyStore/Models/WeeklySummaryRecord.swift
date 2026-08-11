import Foundation
import SwiftData

/// A week's roll-up, persisted **only once its raw events have been swept**.
///
/// While the events exist the summary is derived on read, so there is nothing
/// to keep in sync. This table is what survives the retention sweep — and it is
/// deleted along with the events by delete-everything, because a summary
/// outliving the rows it came from is a record the parent asked us to destroy.
///
/// Nothing writes to this table yet. It is here at v1 because the sweep that
/// fills it (Stage 3) must not be the release that also introduces the table:
/// the retention window is still undecided, and adding storage for a decision
/// is cheaper than migrating history around one.
///
/// `payload` is deliberately opaque. The summary's shape — top artists, top
/// songs, first-time-heard, blocks by artist — is the part most likely to
/// change once a parent has actually read one, and a blob absorbs that without
/// a schema migration. It is a report, not something anything queries.
@Model
public final class WeeklySummaryRecord {
    public private(set) var id: UUID = UUID()

    /// Start of the week this covers. Device time, so approximate.
    public private(set) var weekStart: Date = Date.distantPast

    /// **This table was the one record in the store without it**, against a
    /// stated invariant that every record carries the time it last changed.
    /// Nothing writes here yet, so adding it costs nothing today; the outbox
    /// scan is what needed it, since a record with no `modifiedAt` cannot answer
    /// whether it has changed since the last export.
    public private(set) var modifiedAt: Date = Date.distantPast

    /// **Held outside the row.** An unbounded opaque blob against a 1 MB
    /// `CKRecord` ceiling, and the failure it prevents is the worst-shaped one
    /// in this store: the sweep rolls a heavy week up, the blob exceeds the
    /// ceiling, the local save succeeds, the export fails quietly — and the
    /// sweep has already deleted the raw rows in the same operation. It scales
    /// with how much the child used the app, so it lands first on the weeks a
    /// parent most wants to read.
    ///
    /// Free to add right now for one reason only: nothing writes this table yet,
    /// so there is no stored blob to move. That stops being true the moment the
    /// sweep ships.
    @Attribute(.externalStorage)
    public private(set) var payload: Data = Data()

    public var kid: Kid?

    public init(id: UUID = UUID(), weekStart: Date, payload: Data, at: Date = .now) {
        self.id = id
        self.weekStart = weekStart
        self.payload = payload
        self.modifiedAt = at
    }

    /// Replaces the roll-up, **and does nothing when it has not changed.**
    ///
    /// The sweep re-summarises every eligible week on every pass, because a week's
    /// rows can still arrive from another device. Stamping `modifiedAt` for an
    /// identical payload would put this whole table in the outbox once per pass per
    /// device — and ``WeeklySummary`` is deterministic precisely so that "identical"
    /// is a byte comparison rather than a guess.
    public func replace(payload newPayload: Data, at: Date = .now) {
        guard newPayload != payload else { return }
        payload = newPayload
        modifiedAt = at
    }
}
