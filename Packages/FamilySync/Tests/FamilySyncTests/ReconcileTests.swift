import CloudKit
import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import FamilyStore
@testable import FamilySync

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0 + seconds }

/// One device: a store, and the watermark it has exported up to.
@MainActor
private final class Device {
    let context: ModelContext

    init() throws {
        context = ModelContext(try FamilyStore.inMemoryContainer())
    }

    var target: SyncApply.Context { SyncApply.Context(context) }

    func seed(kid name: String = "Ada") -> (Family, Kid) {
        let family = Family(at: t0)
        let kid = Kid(name: name, mode: .denyPlusAuto, unratedBehavior: .block, at: t0)
        context.insert(family)
        context.insert(kid)
        family.addKid(kid, at: t0)
        return (family, kid)
    }

    /// Everything owed, taken through the CloudKit codec and back so the test
    /// exercises the real path rather than a shortcut past it.
    func outbound() throws -> [Outbox.Change] {
        let changes = try Reconcile.outgoing(in: target)
        // The server accepted them, which is the only thing that marks them
        // agreed. Sending is not accepting.
        Reconcile.accepted(changes, in: target)
        try context.save()
        return changes.map { change in
            switch change {
            case .upsert(let record):
                let zone = FamilyZone.placing(record.type, kidID: UUID()) ?? .household
                let ck = CloudKitCodec.ckRecord(for: record, in: zone)
                return .upsert(CloudKitCodec.syncedRecord(for: ck))
            case .delete: return change
            }
        }
    }

    func receive(_ changes: [Outbox.Change]) throws {
        for change in changes {
            switch change {
            case .upsert(let record): Reconcile.incoming(record, in: target)
            case .delete(let name, let type):
                Reconcile.incomingDeletion(named: name, type: type, in: target)
            }
        }
        try context.save()
    }

    func kid() throws -> Kid? { try context.fetch(FetchDescriptor<Kid>()).first }
}

@MainActor
private func sync(_ from: Device, to: Device) throws {
    try to.receive(try from.outbound())
}

// MARK: -

@Suite("A record's whole journey")
@MainActor
struct WholeJourney {
    /// **Encode, outbox, CKRecord, decode, merge, apply — every layer, in
    /// order.** Each has its own tests; this is the one that would catch two of
    /// them disagreeing about a field name, which is the failure none of the
    /// others can see.
    @Test("A household, a child and a deny cross intact")
    func fullPipeline() throws {
        let a = try Device()
        let b = try Device()
        let (family, kid) = a.seed()
        kid.setMode(.allowOnly, at: at(60))
        kid.addEntry(kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A Band", at: at(120))
        try a.context.save()

        try sync(a, to: b)

        let arrived = try #require(try b.kid())
        #expect(arrived.id == kid.id)
        #expect(arrived.family?.id == family.id)
        #expect(arrived.effectiveMode == .allowOnly)
        #expect(arrived.buildPolicy().policy.entries == [.deny(CatalogID(.artist, "artist-A"))])
    }

    /// Syncing when nothing has changed must send nothing. A pipeline that
    /// re-sends what it already sent is one that never settles — and with two
    /// devices it is an argument that never ends.
    @Test("A second sync with no changes carries nothing")
    func quiescent() throws {
        let a = try Device()
        let b = try Device()
        _ = a.seed()
        try a.context.save()
        try sync(a, to: b)

        #expect(try a.outbound().isEmpty)
    }

    /// The property the whole merge design exists for, exercised through the
    /// real path rather than against hand-built values.
    @Test("Two parents editing one list offline lose nothing")
    func offlineExitTest() throws {
        let a = try Device()
        let b = try Device()
        let (_, kidA) = a.seed()
        let y = kidA.addEntry(
            kind: .allow, id: CatalogID(.album, "album-Y"), displayName: "Y", at: t0)
        try a.context.save()
        try sync(a, to: b)

        // Both go offline. A denies artist X and withdraws Y.
        kidA.addEntry(kind: .deny, id: CatalogID(.artist, "artist-X"), displayName: "X", at: at(600))
        kidA.removeEntry(y, at: at(600))
        try a.context.save()

        // B allows album Z and withdraws the same Y.
        let kidB = try #require(try b.kid())
        kidB.addEntry(kind: .allow, id: CatalogID(.album, "album-Z"), displayName: "Z", at: at(640))
        let yOnB = try #require(kidB.entries.first { $0.catalogID == "album-Y" })
        kidB.removeEntry(yOnB, at: at(640))
        try b.context.save()

        // Both reconnect, in both directions.
        let fromA = try a.outbound()
        let fromB = try b.outbound()
        try b.receive(fromA)
        try a.receive(fromB)

        for device in [a, b] {
            let entries = try #require(try device.kid()).buildPolicy().policy.entries
            #expect(entries.contains(.deny(CatalogID(.artist, "artist-X"))))
            #expect(entries.contains(.allow(CatalogID(.album, "album-Z"))))
            #expect(entries.contains(.allow(CatalogID(.album, "album-Y"))) == false)
            #expect(entries.count == 2)
        }
    }

    /// A withdrawal has to survive the trip, or the retraction mechanism is
    /// decorative. The tombstone is what carries it — a delete would have left
    /// nothing to send.
    @Test("A retraction reaches the other device")
    func retractionCrosses() throws {
        let a = try Device()
        let b = try Device()
        let (_, kid) = a.seed()
        let allow = kid.addEntry(
            kind: .allow, id: CatalogID(.album, "album-A"), displayName: "An Album", at: t0)
        try a.context.save()
        try sync(a, to: b)
        #expect(try #require(try b.kid()).liveEntries.count == 1)

        kid.removeEntry(allow, at: at(600))
        try a.context.save()
        try sync(a, to: b)

        let arrived = try #require(try b.kid())
        #expect(arrived.liveEntries.isEmpty)
        #expect(arrived.entries.count == 1)
    }

    /// A real delete has no row left to describe it, which is what
    /// `PendingDeletionRecord` exists for.
    @Test("A deleted playlist is deleted on the other device too")
    func deletionCrosses() throws {
        let a = try Device()
        let b = try Device()
        let (_, kid) = a.seed()
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)
        playlist.addSong(id: CatalogID(.song, "one"), displayName: "One", at: t0)
        try a.context.save()
        try sync(a, to: b)
        #expect(try b.context.fetch(FetchDescriptor<PlaylistRecord>()).count == 1)

        Outbox.delete(playlist, in: a.context, at: at(600))
        try a.context.save()
        try sync(a, to: b)

        #expect(try b.context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
    }

    /// Out-of-order arrival is normal — two zones have no ordering between
    /// them. A record whose parent has not landed waits rather than vanishing.
    @Test("Records that arrive before their parent are not lost")
    func outOfOrderArrival() throws {
        let a = try Device()
        let b = try Device()
        let (_, kid) = a.seed()
        kid.addEntry(kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: t0)
        try a.context.save()

        // Deliberately backwards: the entry first, the household last.
        let changes = try a.outbound().reversed().map { $0 }
        try b.receive(changes)
        // The entry could not be placed on the first pass.
        #expect(try b.context.fetch(FetchDescriptor<PolicyEntryRecord>()).isEmpty)

        // A retry, which is what the engine does with anything deferred.
        try b.receive(changes)
        #expect(try #require(try b.kid()).liveEntries.count == 1)
    }

    /// Applying the same batch twice must not double anything. Duplicate
    /// delivery is ordinary, not exceptional.
    @Test("Delivering the same batch twice changes nothing the second time")
    func duplicateDelivery() throws {
        let a = try Device()
        let b = try Device()
        let (_, kid) = a.seed()
        kid.addEntry(kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: t0)
        kid.addPlaylist(named: "Car songs", at: t0)
        try a.context.save()

        let changes = try a.outbound()
        try b.receive(changes)
        try b.receive(changes)

        #expect(try b.context.fetch(FetchDescriptor<Kid>()).count == 1)
        #expect(try b.context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)
        #expect(try b.context.fetch(FetchDescriptor<PlaylistRecord>()).count == 1)
    }

    /// Sending back what was just received must be a no-op. Otherwise two
    /// devices bounce a record between them forever, each seeing a change the
    /// other made and echoing it.
    @Test("A received record is not immediately echoed back")
    func noEchoLoop() throws {
        let a = try Device()
        let b = try Device()
        let (_, kid) = a.seed()
        kid.addEntry(kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: t0)
        try a.context.save()

        try sync(a, to: b)
        // B has now imported everything. What does B think it owes?
        let echo = try b.outbound()

        // Imports carry the record's own `modifiedAt`, so nothing looks newer
        // than B's watermark and nothing goes back.
        #expect(echo.isEmpty)
    }
}
