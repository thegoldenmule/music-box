import FamilyStore
import Foundation
import SwiftData

/// What to do with a record that arrived from somewhere else.
///
/// **The last link in the chain, and the only one that had no home.** Encoding
/// lives in `FamilyStore`, merging lives beside it in this package, applying
/// lives back in `FamilyStore` because only that module may write its own
/// models. This is the three of them in order, and it is here rather than in
/// `FamilyStore` because merging is sync *policy* — the store should not know
/// how two copies of a row are reconciled, only how to absorb the answer.
///
/// Deliberately free of CloudKit. The engine host hands it values and takes
/// values back; everything below this line is testable with no network, no
/// entitlement and no device, which is where the design has kept the parts that
/// decide something.
public enum Reconcile {
    /// One arriving record: merge it against what is here, then absorb it.
    ///
    /// **Merge only where there is something to merge against.** A record this
    /// device has never seen is applied as it arrived — there is no local
    /// version to reconcile with, and inventing one by merging against an empty
    /// record would run every field rule against a default and quietly rewrite
    /// timestamps.
    @MainActor
    @discardableResult
    public static func incoming(
        _ remote: SyncedRecord,
        in context: SyncApply.Context
    ) -> SyncApply.Outcome {
        let merged: SyncedRecord
        if let local = SyncApply.localRecord(named: remote.name, type: remote.type, in: context) {
            merged = Merge.resolve(
                local: local, remote: remote, rules: Merge.rules(for: remote.type)
            ).record
        } else {
            merged = remote
        }

        let outcome = SyncApply.apply(merged, in: context)

        // **Marked only when it actually landed.** A deferred record has not
        // been agreed on — it is waiting for a parent to arrive — and marking it
        // would tell the outbox this device is up to date on a row it does not
        // have.
        switch outcome {
        case .inserted, .updated:
            Outbox.markSynced(merged, in: context.modelContext)
        case .deferred, .unknownType:
            break
        }
        return outcome
    }

    /// A deletion that arrived from somewhere else.
    ///
    /// Separate from ``incoming(_:in:)`` because a deletion carries no fields to
    /// merge — there is nothing left of the record to reconcile, which is the
    /// whole reason it needed a tombstone to travel at all.
    @MainActor
    public static func incomingDeletion(
        named name: String,
        type: String,
        in context: SyncApply.Context
    ) {
        SyncApply.deleteLocal(named: name, type: type, in: context)
    }

    /// Everything owed to the server, as records ready to be encoded.
    ///
    /// A thin pass-through today. It exists so the engine host has one place to
    /// ask rather than reaching into `FamilyStore` itself, and so the
    /// back-pressure rule — when there is more owed than a batch can carry —
    /// has somewhere to live that is not inside a CloudKit delegate callback.
    @MainActor
    public static func outgoing(
        in context: SyncApply.Context,
        limit: Int = 200
    ) throws -> [Outbox.Change] {
        try Array(Outbox.pending(in: context.modelContext).prefix(limit))
    }

    /// Records that the server has accepted a batch.
    ///
    /// Separate from sending it, because the two are not the same moment: a
    /// batch that was handed to CloudKit and failed must stay owed. Marking on
    /// send rather than on acknowledgement is how a change goes missing with
    /// everything reporting success.
    @MainActor
    public static func accepted(_ changes: [Outbox.Change], in context: SyncApply.Context) {
        for change in changes {
            switch change {
            case .upsert(let record):
                Outbox.markSynced(record, in: context.modelContext)
            case .delete(let name, _):
                let tombstones = try? context.modelContext.fetch(
                    FetchDescriptor<PendingDeletionRecord>())
                tombstones?.first { $0.recordName == name }?.markExported()
            }
        }
    }
}
