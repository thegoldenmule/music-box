import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import FamilyStore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

@MainActor
private func seeded() throws -> (ModelContext, Kid) {
    let context = ModelContext(try FamilyStore.inMemoryContainer())
    let family = Family(at: t0)
    let kid = Kid(name: "Ada", mode: .denyPlusAuto, at: t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: t0)
    return (context, kid)
}

/// Sends everything, agrees on it, comes back — a converging outbox empties.
@MainActor
private func drain(_ context: ModelContext) throws -> [Outbox.Change] {
    let owed = try Outbox.pending(in: context)
    let tombstones = try context.fetch(FetchDescriptor<PendingDeletionRecord>())
    for change in owed {
        switch change {
        case .upsert(let record):
            Outbox.markSynced(record, in: context)
        case .delete(let name, _):
            // A tombstone is owed until told, same as a record, or drain never finishes.
            tombstones.first { $0.recordName == name }?.markExported()
        }
    }
    try context.save()
    return owed
}

// MARK: -

/// A fresh UUID() per orphan meant the outbox never drained; found by running it.
@Suite("An orphaned row is never sent")
@MainActor
struct OrphanExport {
    /// The direct statement: no parent, no name.
    @Test("A row with no parent cannot name itself")
    func noParentNoName() throws {
        let (context, kid) = try seeded()
        let favorite = try #require(kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B"))
        #expect(favorite.syncRecordName != nil)

        favorite.kid = nil
        #expect(favorite.syncRecordName == nil)
        #expect(favorite.syncRecord() == nil)
    }

    /// Two exports of an unchanged store must name the same records — that was false.
    @Test("Two passes over an unchanged store agree on every name")
    func namesAreStable() throws {
        let (context, kid) = try seeded()
        let favorite = try #require(kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B"))
        let playlist = kid.addPlaylist(named: "Car songs")
        _ = playlist.addSong(id: CatalogID(.song, "c"), displayName: "C")
        try context.save()

        // Detached by hand — context.save() keeps it; nulling an inverse isn't a delete.
        favorite.kid = nil
        try context.save()

        let first = try Outbox.pending(in: context).compactMap(\.recordName).sorted()
        let second = try Outbox.pending(in: context).compactMap(\.recordName).sorted()

        #expect(first == second)
    }

    /// The consequence: "Sync now"'s number reaches zero and stays there.
    @Test("The outbox drains, and stays drained")
    func outboxConverges() throws {
        let (context, kid) = try seeded()
        _ = kid.addFavorite(id: CatalogID(.album, "kept"), displayName: "Kept")
        let doomed = try #require(
            kid.addFavorite(id: CatalogID(.album, "gone"), displayName: "Gone"))
        let playlist = kid.addPlaylist(named: "Car songs")
        let song = try #require(playlist.addSong(id: CatalogID(.song, "c"), displayName: "C"))
        try context.save()

        doomed.kid = nil
        song.playlist = nil
        try context.save()

        #expect(try drain(context).isEmpty == false)
        #expect(try drain(context).isEmpty)
        #expect(try drain(context).isEmpty)
    }

    /// Marks grew unbounded first — one new mark per orphan per sync, forever.
    @Test("Syncing repeatedly does not grow the marks table")
    func marksDoNotGrow() throws {
        let (context, kid) = try seeded()
        let doomed = try #require(kid.addFavorite(id: CatalogID(.album, "x"), displayName: "X"))
        try context.save()
        doomed.kid = nil
        try context.save()

        _ = try drain(context)
        let settled = try context.fetch(FetchDescriptor<SyncMarkRecord>()).count
        _ = try drain(context)
        _ = try drain(context)

        #expect(try context.fetch(FetchDescriptor<SyncMarkRecord>()).count == settled)
    }

    /// Holding orphans back must not also hold back a child's real playlist.
    @Test("Everything with a parent still goes")
    func liveRowsAreUnaffected() throws {
        let (context, kid) = try seeded()
        let kept = try #require(kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B"))
        let doomed = try #require(kid.addFavorite(id: CatalogID(.album, "d"), displayName: "D"))
        try context.save()
        doomed.kid = nil
        try context.save()

        let names = try Outbox.pending(in: context).compactMap(\.recordName)
        #expect(names.contains(try #require(kept.syncRecordName)))
        #expect(names.count == 3)  // family, kid, the surviving favorite
    }
}

// MARK: -

/// The other half: the removals that produced the orphans in the first place.
@Suite("Removing something removes it")
@MainActor
struct RemovalDeletes {
    @Test("Un-hearting a favorite deletes the row")
    func favoriteIsDeleted() throws {
        let (context, kid) = try seeded()
        _ = kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B")
        try context.save()

        kid.removeFavorite(CatalogID(.album, "b"))
        try context.save()

        #expect(try context.fetch(FetchDescriptor<FavoriteRecord>()).isEmpty)
    }

    /// Without a tombstone the favorite stays on a co-parent's phone forever.
    @Test("Un-hearting a favorite tells the other device")
    func favoriteDeletionTravels() throws {
        let (context, kid) = try seeded()
        let favorite = try #require(kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B"))
        let name = try #require(favorite.syncRecordName)
        try context.save()

        kid.removeFavorite(CatalogID(.album, "b"))
        try context.save()

        let owed = try Outbox.pending(in: context)
        #expect(owed.contains(.delete(name: name, type: "FavoriteRecord")))
    }

    /// Cascade fires on the kid, not the playlist — songs need their own delete call.
    @Test("Throwing a playlist away takes its songs")
    func playlistTakesItsSongs() throws {
        let (context, kid) = try seeded()
        let playlist = kid.addPlaylist(named: "Car songs")
        _ = playlist.addSong(id: CatalogID(.song, "c"), displayName: "C")
        _ = playlist.addSong(id: CatalogID(.song, "d"), displayName: "D")
        try context.save()

        kid.removePlaylist(playlist)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistEntryRecord>()).isEmpty)
    }

    @Test("Pulling a song out of a playlist deletes it and says so")
    func songRemovalTravels() throws {
        let (context, kid) = try seeded()
        let playlist = kid.addPlaylist(named: "Car songs")
        let song = try #require(playlist.addSong(id: CatalogID(.song, "c"), displayName: "C"))
        _ = playlist.addSong(id: CatalogID(.song, "d"), displayName: "D")
        let name = try #require(song.syncRecordName)
        try context.save()

        playlist.removeSong(CatalogID(.song, "c"))
        try context.save()

        #expect(try context.fetch(FetchDescriptor<PlaylistEntryRecord>()).count == 1)
        #expect(try Outbox.pending(in: context).contains(
            .delete(name: name, type: "PlaylistEntryRecord")))
    }

    /// A removal must converge too — the point of both halves being here.
    @Test("A removal converges too")
    func removalConverges() throws {
        let (context, kid) = try seeded()
        _ = kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B")
        try context.save()
        _ = try drain(context)

        kid.removeFavorite(CatalogID(.album, "b"))
        try context.save()

        #expect(try drain(context).isEmpty == false)
        #expect(try drain(context).isEmpty)
    }
}

// MARK: -

@Suite("Reaping what earlier builds left behind")
@MainActor
struct OrphanRepair {
    /// Every query is `kid?.id == kidID`, so an orphan is invisible, not just unused.
    @Test("Orphans are found and counted")
    func orphansAreReaped() throws {
        let (context, kid) = try seeded()
        let favorite = try #require(kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B"))
        let entry = kid.addEntry(kind: .deny, id: CatalogID(.artist, "a"), displayName: "A")
        let playlist = kid.addPlaylist(named: "Car songs")
        let song = try #require(playlist.addSong(id: CatalogID(.song, "c"), displayName: "C"))
        try context.save()

        favorite.kid = nil
        entry.kid = nil
        song.playlist = nil
        try context.save()

        #expect(try Outbox.orphans(in: context) == 3)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<FavoriteRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistEntryRecord>()).isEmpty)
    }

    /// It must never touch a row that is still somebody's.
    @Test("A healthy store has nothing to reap")
    func healthyStoreIsUntouched() throws {
        let (context, kid) = try seeded()
        _ = kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B")
        _ = kid.addEntry(kind: .deny, id: CatalogID(.artist, "a"), displayName: "A")
        let playlist = kid.addPlaylist(named: "Car songs")
        _ = playlist.addSong(id: CatalogID(.song, "c"), displayName: "C")
        try context.save()

        #expect(try Outbox.orphans(in: context) == 0)
        #expect(try context.fetch(FetchDescriptor<FavoriteRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PlaylistEntryRecord>()).count == 1)
    }

    /// A retracted entry still syncs — reaping it would resurrect the deny elsewhere.
    @Test("A retraction is kept, not reaped")
    func retractionsSurvive() throws {
        let (context, kid) = try seeded()
        let entry = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "a"), displayName: "A", at: t0)
        try context.save()
        kid.removeEntry(entry, at: at(60))
        try context.save()

        #expect(try Outbox.orphans(in: context) == 0)
        #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)
        #expect(entry.isLive == false)
    }
}

extension Outbox.Change {
    fileprivate var recordName: String? {
        switch self {
        case .upsert(let record): record.name
        case .delete: nil
        }
    }
}
