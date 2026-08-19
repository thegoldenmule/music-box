import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0 + seconds }

@MainActor
private func newStore() throws -> ModelContext {
    ModelContext(try FamilyStore.inMemoryContainer())
}

/// Two independent stores, standing in for two devices.
@MainActor
private func twoDevices() throws -> (a: ModelContext, b: ModelContext) {
    (try newStore(), try newStore())
}

@MainActor
private func seedFamily(_ context: ModelContext, kid name: String = "Ada") -> (Family, Kid) {
    let family = Family(at: t0)
    let kid = Kid(name: name, mode: .denyPlusAuto, unratedBehavior: .block, at: t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: t0)
    return (family, kid)
}

// MARK: -

@Suite("Absorbing a record another device wrote")
@MainActor
struct Applying {
    /// End to end: a household created on one device turns up whole on the other.
    @Test("A household, a child and a deny cross to a second device")
    func fullRoundTrip() throws {
        let (a, b) = try twoDevices()
        let (family, kid) = seedFamily(a)
        kid.setMode(.allowOnly, at: at(60))
        let deny = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A Band", at: at(120))
        try a.save()

        let outbound = try Outbox.pending(in: a)
        let target = SyncApply.Context(b)
        for change in outbound {
            guard case .upsert(let record) = change else { continue }
            _ = SyncApply.apply(record, in: target)
        }
        try b.save()

        let arrived = try #require(try b.fetch(FetchDescriptor<Kid>()).first)
        #expect(arrived.id == kid.id)
        #expect(arrived.name == "Ada")
        #expect(arrived.family?.id == family.id)
        #expect(arrived.effectiveMode == .allowOnly)
        #expect(arrived.liveEntries.count == 1)
        #expect(arrived.buildPolicy().policy.entries == [.deny(deny.entry!.id)])
    }

    /// Out-of-order arrival is normal — a record kept and retried, never dropped.
    @Test("A record whose parent has not arrived is deferred, not dropped")
    func missingParentDefers() throws {
        let (a, b) = try twoDevices()
        let (_, kid) = seedFamily(a)
        let deny = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: at(60))
        try a.save()

        // The entry arrives before its kid.
        let outcome = SyncApply.apply(deny.record, in: SyncApply.Context(b))
        #expect(outcome == .deferred(.missingParent(Field.kidID)))
        #expect(try b.fetch(FetchDescriptor<PolicyEntryRecord>()).isEmpty)
    }

    @Test("Retrying a deferred record once its parent lands works")
    func deferredRecordSucceedsOnRetry() throws {
        let (a, b) = try twoDevices()
        let (family, kid) = seedFamily(a)
        let deny = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: at(60))
        try a.save()

        let target = SyncApply.Context(b)
        #expect(SyncApply.apply(deny.record, in: target) == .deferred(.missingParent(Field.kidID)))

        _ = SyncApply.apply(family.record, in: target)
        _ = SyncApply.apply(kid.record, in: target)
        #expect(SyncApply.apply(deny.record, in: target) == .inserted)
        try b.save()

        #expect(try b.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)
    }

    /// Matches on the natural key, not `id` — two devices mint different ids.
    @Test("Applying twice inserts once")
    func applyIsIdempotent() throws {
        let (a, b) = try twoDevices()
        let (family, kid) = seedFamily(a)
        let deny = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: at(60))
        try a.save()

        let target = SyncApply.Context(b)
        _ = SyncApply.apply(family.record, in: target)
        _ = SyncApply.apply(kid.record, in: target)
        #expect(SyncApply.apply(deny.record, in: target) == .inserted)
        #expect(SyncApply.apply(deny.record, in: target) == .updated)
        try b.save()

        #expect(try b.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)
    }

    /// A different `id`, same natural key — must land on the row already here.
    @Test("A twin minted elsewhere lands on the row already here")
    func twinCollapsesOntoOneRow() throws {
        let (a, b) = try twoDevices()
        let (family, kid) = seedFamily(a)
        try a.save()

        let target = SyncApply.Context(b)
        _ = SyncApply.apply(family.record, in: target)
        _ = SyncApply.apply(kid.record, in: target)

        // B already has its own row for the same deny.
        let localKid = try #require(try b.fetch(FetchDescriptor<Kid>()).first)
        let mine = localKid.addEntry(
            kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: at(30))

        let theirs = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: at(60))
        #expect(mine.id != theirs.id)
        #expect(mine.syncRecordName == theirs.syncRecordName)

        #expect(SyncApply.apply(theirs.record, in: target) == .updated)
        try b.save()
        #expect(try b.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)
    }

    /// A withdrawal has to survive the trip, or retraction is decorative.
    @Test("A retraction crosses and takes the entry off the policy")
    func retractionCrosses() throws {
        let (a, b) = try twoDevices()
        let (family, kid) = seedFamily(a)
        let allow = kid.addEntry(
            kind: .allow, id: CatalogID(.album, "album-A"), displayName: "An Album", at: at(60))
        try a.save()

        let target = SyncApply.Context(b)
        _ = SyncApply.apply(family.record, in: target)
        _ = SyncApply.apply(kid.record, in: target)
        _ = SyncApply.apply(allow.record, in: target)

        let arrived = try #require(try b.fetch(FetchDescriptor<Kid>()).first)
        #expect(arrived.liveEntries.count == 1)

        kid.removeEntry(allow, at: at(600))
        _ = SyncApply.apply(allow.record, in: target)

        #expect(arrived.liveEntries.isEmpty)
        #expect(arrived.entries.count == 1)  // the tombstone stays
    }

    /// Absence is never a vote — a copy with no `retractedAt` can't undo one.
    @Test("A stale copy cannot undo a retraction")
    func staleCopyCannotResurrect() throws {
        let context = try newStore()
        let (_, kid) = seedFamily(context)
        let allow = kid.addEntry(
            kind: .allow, id: CatalogID(.album, "album-A"), displayName: "An Album", at: at(60))
        let staleCopy = allow.record  // captured before the withdrawal

        kid.removeEntry(allow, at: at(600))
        #expect(allow.isLive == false)

        _ = SyncApply.apply(staleCopy, in: SyncApply.Context(context))
        #expect(allow.isLive == false)
    }

    /// Importing must not look like editing, or the next export ping-pongs it back.
    @Test("An import carries the record's own timestamp, not now")
    func importDoesNotStampNow() throws {
        let (a, b) = try twoDevices()
        let (family, kid) = seedFamily(a)
        kid.rename(to: "Ada B", at: at(600))
        try a.save()

        let target = SyncApply.Context(b)
        _ = SyncApply.apply(family.record, in: target)
        _ = SyncApply.apply(kid.record, in: target)

        let arrived = try #require(try b.fetch(FetchDescriptor<Kid>()).first)
        #expect(arrived.modifiedAt == at(600))
    }

    /// Not through `setMode` — that would record a new decision, at the wrong time.
    @Test("An arriving decision is not re-decided locally")
    func decisionsAreNotReDecided() throws {
        let (a, b) = try twoDevices()
        let (family, kid) = seedFamily(a)
        kid.setMode(.allowOnly, at: at(600))
        try a.save()

        let target = SyncApply.Context(b)
        _ = SyncApply.apply(family.record, in: target)
        _ = SyncApply.apply(kid.record, in: target)
        let decision = try #require(kid.sandboxSettings.first)
        #expect(SyncApply.apply(decision.record, in: target) == .inserted)
        // Twice is once — a decision is never edited.
        #expect(SyncApply.apply(decision.record, in: target) == .updated)

        let arrived = try #require(try b.fetch(FetchDescriptor<Kid>()).first)
        #expect(arrived.sandboxSettings.count == 1)
        #expect(arrived.sandboxSettings.first?.decidedAt == at(600))
        #expect(arrived.effectiveMode == .allowOnly)
    }

    /// A value from a newer build falls back to the most restrictive, not a crash.
    @Test("An unreadable sandbox level fails closed")
    func unreadableModeFailsClosed() throws {
        let context = try newStore()
        let target = SyncApply.Context(context)

        var record = Kid(name: "Ada", mode: .reportOnly, at: t0).record
        record["mode"] = .string("someLevelFromTheFuture")
        #expect(SyncApply.apply(record, in: target) == .inserted)

        let arrived = try #require(try context.fetch(FetchDescriptor<Kid>()).first)
        #expect(arrived.effectiveMode == .allowOnly)
    }

    @Test("A record type this build does not know is reported, not dropped silently")
    func unknownTypeIsReported() throws {
        let context = try newStore()
        let record = SyncedRecord(name: "x", type: "SomethingFromTheFuture", fields: [:])
        #expect(SyncApply.apply(record, in: SyncApply.Context(context)) == .unknownType("SomethingFromTheFuture"))
    }
}

// MARK: -

@Suite("What this device still owes the server")
@MainActor
struct OutboxTests {
    /// No enqueue at any call site — derived from `modifiedAt`, so none can forget.
    @Test("Everything the server has not agreed to is pending")
    func changesAreDerived() throws {
        let context = try newStore()
        let (_, kid) = seedFamily(context)
        try context.save()

        let afterSeed = try Outbox.pending(in: context)
        #expect(afterSeed.count == 2)  // the household and the child

        // Once the server has agreed, nothing is owed.
        for change in afterSeed {
            if case .upsert(let record) = change { Outbox.markSynced(record, in: context) }
        }
        try context.save()
        #expect(try Outbox.pending(in: context).isEmpty)

        // A local edit moves `modifiedAt`, so the row is owed again.
        kid.rename(to: "Ada B", at: at(600))
        try context.save()

        let pending = try Outbox.pending(in: context)
        #expect(pending.count == 1)
        #expect(pending.first?.recordName == kid.syncRecordName)
    }

    /// The one gap a `modifiedAt` scan can't cover — a deleted row reports nothing.
    @Test("A delete is owed even though the row is gone")
    func deletionsAreOwed() throws {
        let context = try newStore()
        let (_, kid) = seedFamily(context)
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)
        try context.save()
        let name = try #require(playlist.syncRecordName)

        Outbox.delete(playlist, in: context, at: at(600))
        try context.save()

        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
        let pending = try Outbox.pending(in: context)
        #expect(pending.contains(.delete(name: name, type: "PlaylistRecord")))
    }

    /// Captured while the row still exists — no recovering a derived name after.
    @Test("The tombstone carries the name the record had")
    func tombstoneCarriesTheName() throws {
        let context = try newStore()
        let (_, kid) = seedFamily(context)
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)
        let expected = playlist.syncRecordName

        Outbox.delete(playlist, in: context, at: at(600))
        try context.save()

        let tombstone = try #require(try context.fetch(FetchDescriptor<PendingDeletionRecord>()).first)
        #expect(tombstone.recordName == expected)
        #expect(tombstone.recordType == "PlaylistRecord")
        #expect(tombstone.exportedAt == nil)
    }

    @Test("An exported tombstone stops being owed")
    func exportedTombstonesAreQuiet() throws {
        let context = try newStore()
        let (_, kid) = seedFamily(context)
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)
        Outbox.delete(playlist, in: context, at: at(600))
        try context.save()

        let tombstone = try #require(try context.fetch(FetchDescriptor<PendingDeletionRecord>()).first)
        tombstone.markExported(at: at(700))
        try context.save()

        let pending = try Outbox.pending(in: context)
        #expect(pending.contains { if case .delete = $0 { true } else { false } } == false)
    }

    /// A device offline past the window just re-uploads — the cost is paid here.
    @Test("The sweep takes only exported tombstones past the window")
    func sweepIsConservative() throws {
        let context = try newStore()
        let (_, kid) = seedFamily(context)
        let old = kid.addPlaylist(named: "Old", at: t0)
        let recent = kid.addPlaylist(named: "Recent", at: t0)

        Outbox.delete(old, in: context, at: at(0))
        Outbox.delete(recent, in: context, at: at(10_000))
        try context.save()

        for tombstone in try context.fetch(FetchDescriptor<PendingDeletionRecord>()) {
            tombstone.markExported(at: at(10_100))
        }
        // An un-exported one must survive the sweep whatever its age.
        let unexported = PendingDeletionRecord(recordName: "x", recordType: "PlaylistRecord", at: at(0))
        context.insert(unexported)
        try context.save()

        #expect(try Outbox.sweepTombstones(olderThan: at(5_000), in: context) == 1)
        try context.save()

        let left = try context.fetch(FetchDescriptor<PendingDeletionRecord>())
        #expect(left.count == 2)
        #expect(left.contains { $0.exportedAt == nil })
    }

    /// Describes this device's own exchange, not the household — must not travel.
    @Test("The outbox itself does not sync")
    func outboxIsLocal() {
        let never = Set(SyncCoverage.neverSyncs.map { String(describing: $0) })
        #expect(never.contains("PendingDeletionRecord"))
    }
}

// MARK: -

@Suite("Everything that can be sent can be received")
@MainActor
struct ApplyCoverage {
    /// Encodes-but-doesn't-apply is a row that silently never arrives — no error.
    @Test("The apply list and the encode list agree exactly")
    func coverageMatches() {
        #expect(SyncApply.applicableTypes == RecordMapper.encodableTypes)
    }

    /// A name with no `case` behind it would pass the test above and still fail.
    @Test("Every declared type dispatches to something")
    func everyTypeDispatches() throws {
        let context = try newStore()
        let target = SyncApply.Context(context)

        for type in SyncApply.applicableTypes {
            let empty = SyncedRecord(name: "x", type: type, fields: [:])
            let outcome = SyncApply.apply(empty, in: target)
            // Must fail as deferred, not unknownType — proving the case exists.
            #expect(outcome != .unknownType(type), "no case for \(type)")
        }
    }
}

// MARK: -

@Suite("The kid's own work crosses intact")
@MainActor
struct LibraryRoundTrip {
    /// A playlist's natural key *is* its id — minting a fresh one would duplicate it.
    @Test("A playlist and its songs cross with their identity intact")
    func playlistCrosses() throws {
        let (a, b) = try twoDevices()
        let (family, kid) = seedFamily(a)
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)
        playlist.addSong(id: CatalogID(.song, "one"), displayName: "One", at: at(10))
        playlist.addSong(id: CatalogID(.song, "two"), displayName: "Two", at: at(20))
        try a.save()

        let target = SyncApply.Context(b)
        for change in try Outbox.pending(in: a) {
            guard case .upsert(let record) = change else { continue }
            _ = SyncApply.apply(record, in: target)
        }
        try b.save()

        let arrived = try #require(try b.fetch(FetchDescriptor<PlaylistRecord>()).first)
        #expect(arrived.id == playlist.id)
        #expect(arrived.syncRecordName == playlist.syncRecordName)
        #expect(arrived.name == "Car songs")
        #expect(arrived.row.entries.map(\.catalogID.rawValue) == ["one", "two"])
        #expect(arrived.kid?.id == kid.id)
        #expect(try b.fetch(FetchDescriptor<Family>()).first?.id == family.id)
    }

    /// A row the child chose must never degrade to one the account adopted.
    @Test("An adopted favorite arriving cannot demote one the kid chose")
    func kidOriginNeverDegrades() throws {
        let context = try newStore()
        let (_, kid) = seedFamily(context)
        let mine = try #require(
            kid.addFavorite(
                id: CatalogID(.album, "album-A"), displayName: "A", origin: .kid, at: t0))

        var incoming = mine.record
        incoming["origin"] = .string(LibraryOrigin.appleLibrary.rawValue)
        incoming[Field.modifiedAt] = .date(at(600))
        _ = SyncApply.apply(incoming, in: SyncApply.Context(context))

        #expect(mine.libraryOrigin == .kid)
    }

    /// A device with no `restoredAt` must not be able to put the tile back.
    @Test("A suggestion crosses with both halves of its dismissal")
    func suggestionDismissalCrosses() throws {
        let (a, b) = try twoDevices()
        let (family, kid) = seedFamily(a)
        let suggestion = kid.addSuggestion(
            target: .catalog(CatalogID(.album, "album-A")), displayName: "An Album", at: t0)
        suggestion.dismiss(at: at(600))
        try a.save()

        let target = SyncApply.Context(b)
        _ = SyncApply.apply(family.record, in: target)
        _ = SyncApply.apply(kid.record, in: target)
        _ = SyncApply.apply(suggestion.record, in: target)

        let arrived = try #require(try b.fetch(FetchDescriptor<SuggestionRecord>()).first)
        #expect(arrived.isDismissed)
        #expect(arrived.allowedIDs.isEmpty)

        // The parent re-offers it, and that crosses too.
        kid.restoreSuggestion(suggestion, at: at(1200))
        _ = SyncApply.apply(suggestion.record, in: target)
        #expect(arrived.isDismissed == false)

        // And a stale copy taken before the restore cannot undo it.
        var stale = suggestion.record
        stale[Field.restoredAt] = nil
        _ = SyncApply.apply(stale, in: target)
        #expect(arrived.isDismissed == false)
    }

    /// A device with no `revokedAt` yet — that absence must never un-revoke.
    @Test("A revocation crosses and cannot be undone by a stale copy")
    func revocationCrosses() throws {
        let context = try newStore()
        let device = DeviceRecord(label: "Sam's iPad", role: .kidOnly, platform: .pad, at: t0)
        context.insert(device)
        let beforeRevoking = device.record

        device.revoke(at: at(600))
        let target = SyncApply.Context(context)
        _ = SyncApply.apply(beforeRevoking, in: target)

        #expect(device.isRevoked)
        #expect(device.revokedAt == at(600))
    }
}
