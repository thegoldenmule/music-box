import CloudKit
import FamilyStore
import Foundation
import SwiftData

/// Where `CKSyncEngine`'s own state lives between launches.
///
/// **Device-local and never synced**, on the same shelf as `DeviceLibraryState`
/// and `ActingGrownUp`: it describes what this device has fetched, not anything
/// about the household. Losing it is survivable — the engine re-fetches — so it
/// is `UserDefaults` rather than anything more careful.
public protocol SyncStateStore: Sendable {
    func state(for scope: String) -> Data?
    func save(_ state: Data?, for scope: String)
}

public struct UserDefaultsSyncState: SyncStateStore {
    public static let prefix = "com.thegoldenmule.auralsandbox.syncState."

    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func state(for scope: String) -> Data? {
        defaults.data(forKey: Self.prefix + scope)
    }

    public func save(_ state: Data?, for scope: String) {
        guard let state else { return defaults.removeObject(forKey: Self.prefix + scope) }
        defaults.set(state, forKey: Self.prefix + scope)
    }
}

public final class InMemorySyncState: SyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]

    public init() {}

    public func state(for scope: String) -> Data? { lock.withLock { stored[scope] } }
    public func save(_ state: Data?, for scope: String) {
        lock.withLock { stored[scope] = state }
    }
}

/// What the admin can say about sync without lying.
public struct SyncStatus: Sendable, Equatable {
    public var lastSucceeded: Date?
    public var lastError: String?
    public var pendingCount: Int = 0
    public var isRunning = false

    public init() {}
}

// MARK: -

/// Runs `CKSyncEngine` in both directions.
///
/// **Deliberately thin, and that is the whole design showing up at the end.**
/// Every decision worth arguing about happens somewhere else and is tested
/// there: what a record is called (`NaturalKey`), how two copies reconcile
/// (`Merge`), which zone it belongs in (`FamilyZone`), what a household owes
/// (`Outbox`), how an arrival is absorbed (`SyncApply`). What is left here is
/// plumbing between them and CloudKit, which is exactly the part no test on
/// this machine can prove.
///
/// **Two engines, because a share has two sides.** The private database is what
/// this account owns; the shared database is what other people have let it
/// into. A co-parent reads the household through the second and writes back
/// through it, and the two have separate state.
///
/// **`CKSyncEngine`'s pending-change queue is a transport detail, not the
/// outbox.** The outbox is still derived from `modifiedAt` against
/// `SyncMarkRecord`, which is what avoids an enqueue at every mutation site.
/// This pushes that answer into the engine when it is time to send — so a call
/// site that forgets to notify is still not a change that goes missing, it is
/// at worst a change that waits for the next sweep.
@MainActor
public final class SyncEngineHost: NSObject {
    public private(set) var status = SyncStatus()

    private let modelContext: ModelContext
    private let stateStore: SyncStateStore
    private let container: CKContainer

    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?

    private var target: SyncApply.Context { SyncApply.Context(modelContext) }

    public init(
        modelContext: ModelContext,
        containerIdentifier: String = "iCloud.com.thegoldenmule.auralsanbox",
        stateStore: SyncStateStore = UserDefaultsSyncState()
    ) {
        self.modelContext = modelContext
        self.stateStore = stateStore
        container = CKContainer(identifier: containerIdentifier)
        super.init()
    }

    /// Brings both engines up.
    ///
    /// Separate from `init` because it talks to CloudKit, and a store that
    /// cannot be opened is a startup failure while a sync that cannot start is
    /// not — the app works offline and must keep working when iCloud is absent.
    public func start(kids: [UUID]) {
        privateEngine = makeEngine(database: container.privateCloudDatabase, scope: "private")
        sharedEngine = makeEngine(database: container.sharedCloudDatabase, scope: "shared")

        // The zones have to exist before anything can be written into them.
        // Only on the private side: zones in the shared database belong to
        // whoever shared them.
        let zones = SharePlan.zones(kids: kids).map { CKRecordZone(zoneID: $0.id) }
        privateEngine?.state.add(pendingDatabaseChanges: zones.map { .saveZone($0) })
    }

    private func makeEngine(database: CKDatabase, scope: String) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: decodedState(for: scope),
            delegate: self
        )
        configuration.automaticallySync = true
        return CKSyncEngine(configuration)
    }

    private func decodedState(for scope: String) -> CKSyncEngine.State.Serialization? {
        guard let data = stateStore.state(for: scope) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    /// Tells the engine what the store currently owes.
    ///
    /// Called after a local edit and on launch. Deriving rather than being told
    /// means a caller that forgets costs a delay, not a lost change.
    public func pushPendingChanges() {
        guard let privateEngine else { return }
        do {
            let owed = try Reconcile.outgoing(in: target)
            status.pendingCount = owed.count
            guard !owed.isEmpty else { return }

            let changes: [CKSyncEngine.PendingRecordZoneChange] = owed.compactMap { change in
                guard let id = recordID(for: change) else { return nil }
                return switch change {
                case .upsert: .saveRecord(id)
                case .delete: .deleteRecord(id)
                }
            }
            privateEngine.state.add(pendingRecordZoneChanges: changes)
        } catch {
            status.lastError = error.localizedDescription
        }
    }

    /// Where a change belongs, or `nil` when it cannot be placed.
    ///
    /// A kid-scoped record with no kid has nowhere to go, and guessing would put
    /// one child's data in another child's zone — so it is held back rather than
    /// sent somewhere plausible.
    private func recordID(for change: Outbox.Change) -> CKRecord.ID? {
        switch change {
        case .upsert(let record):
            guard let zone = FamilyZone.placing(record.type, kidID: kidID(of: record)) else {
                return nil
            }
            return CKRecord.ID(recordName: record.name, zoneID: zone.id)
        case .delete(let name, let type):
            // A deleted row cannot say which kid it belonged to, so the
            // tombstone's zone has to come from the type alone. Household-scoped
            // types are unambiguous; kid-scoped ones are not, which is why
            // `PendingDeletionRecord` will eventually need the zone on it.
            guard let zone = FamilyZone.placing(type, kidID: nil) else { return nil }
            return CKRecord.ID(recordName: name, zoneID: zone.id)
        }
    }

    /// Which child's zones a record belongs in.
    ///
    /// **Explicit rather than a fallback, and the fallback was a real bug.** It
    /// read `kidID ?? id`, which is right for `Kid` — whose own identifier *is*
    /// the kid — and silently wrong for anything else that lacks a `kidID`. A
    /// playlist song was placed in `kid-<its own id>-work`, a zone that does not
    /// exist, so it could never be sent. Nothing failed; the outbox simply never
    /// drained, which is the only reason it was noticed.
    private func kidID(of record: SyncedRecord) -> UUID? {
        record.type == Kid.syncRecordType ? record.uuid(Field.id) : record.uuid(Field.kidID)
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncEngineHost: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            let scope = syncEngine.database.databaseScope == .private ? "private" : "shared"
            stateStore.save(try? JSONEncoder().encode(update.stateSerialization), for: scope)

        case .fetchedRecordZoneChanges(let changes):
            absorb(modifications: changes.modifications, deletions: changes.deletions)

        case .sentRecordZoneChanges(let sent):
            acknowledge(sent)

        case .accountChange(let change):
            // The binding rules treat a changed account as a lock rather than a
            // switch. Nothing is deleted here: `BindingResolver` decides what
            // the device may open, and doing it there keeps the decision in one
            // testable place.
            if case .signOut = change.changeType { status.lastError = "Signed out of iCloud." }

        case .willFetchChanges, .didFetchChanges, .willSendChanges, .didSendChanges,
            .fetchedDatabaseChanges, .sentDatabaseChanges, .willFetchRecordZoneChanges,
            .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await self.record(for: id)
        }
    }

    /// Builds the `CKRecord` for one pending save.
    ///
    /// Returning `nil` tells the engine to drop the pending change, which is
    /// right for a row that has since been deleted locally and wrong for
    /// anything else — so the only `nil` here is genuine absence.
    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let zone = FamilyZone(zoneName: id.zoneID.zoneName) else { return nil }
        _ = zone
        guard
            let owed = try? Reconcile.outgoing(in: target),
            case .upsert(let synced)? = owed.first(where: { $0.recordName == id.recordName })
        else { return nil }

        let ck = CloudKitCodec.ckRecord(for: synced, in: FamilyZone(zoneName: id.zoneID.zoneName)!)
        return ck
    }

    private func absorb(
        modifications: [CKDatabase.RecordZoneChange.Modification],
        deletions: [CKDatabase.RecordZoneChange.Deletion]
    ) {
        for modification in modifications {
            Reconcile.incoming(CloudKitCodec.syncedRecord(for: modification.record), in: target)
        }
        for deletion in deletions {
            Reconcile.incomingDeletion(
                named: deletion.recordID.recordName, type: deletion.recordType, in: target)
        }
        save()
    }

    private func acknowledge(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        // **Marked on acceptance, never on send.** A record handed to CloudKit
        // that then failed must stay owed; marking when it left is how a change
        // goes missing with everything reporting success.
        let accepted = sent.savedRecords.map { ck in
            Outbox.Change.upsert(CloudKitCodec.syncedRecord(for: ck))
        }
        Reconcile.accepted(accepted, in: target)

        for failure in sent.failedRecordSaves {
            // A record the server has a newer version of. The merge is where
            // that is settled, so the server's copy is absorbed and the row goes
            // back into the outbox rather than being forced over the top.
            if failure.error.code == .serverRecordChanged,
                let server = failure.error.serverRecord
            {
                Reconcile.incoming(CloudKitCodec.syncedRecord(for: server), in: target)
            } else {
                status.lastError = failure.error.localizedDescription
            }
        }

        for deletion in sent.deletedRecordIDs {
            Reconcile.accepted(
                [.delete(name: deletion.recordName, type: "")], in: target)
        }

        save()
        status.lastSucceeded = .now
    }

    private func save() {
        do {
            try modelContext.save()
            status.lastError = nil
        } catch {
            status.lastError = error.localizedDescription
        }
    }
}
