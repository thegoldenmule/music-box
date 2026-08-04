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

/// Drains the outbox the way a device does: send everything, agree on it, and
/// come back. A converging outbox is empty the second time.
@MainActor
private func drain(_ context: ModelContext) throws -> [Outbox.Change] {
    let owed = try Outbox.pending(in: context)
    let tombstones = try context.fetch(FetchDescriptor<PendingDeletionRecord>())
    for change in owed {
        switch change {
        case .upsert(let record):
            Outbox.markSynced(record, in: context)
        case .delete(let name, _):
            // A tombstone is owed until the server has been told, exactly like a
            // record is owed until it is marked. Forgetting this half is its own
            // way for an outbox never to drain.
            tombstones.first { $0.recordName == name }?.markExported()
        }
    }
    try context.save()
    return owed
}

// MARK: -

/// **The bug this suite exists for, and it was found by running the thing
/// rather than by reading it.**
///
/// A row whose parent relationship has been nulled cannot derive its natural
/// key. The mapper used to answer that with a fresh `UUID()`, so the same dead
/// row was exported under a different name on every pass: the outbox never
/// drained, the CloudKit zone grew by one record per orphan per sync, and
/// nothing anywhere reported a problem, because from the sending side it looked
/// exactly like ordinary work.
///
/// The store on the maintainer's device has these — earlier builds' removal
/// paths all detached instead of deleting — so this is not hypothetical and not
/// only about new data.
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

    /// **The regression that matters.** Two exports of an unchanged store have
    /// to name the same records — this is what was false, and it is what made
    /// convergence impossible rather than merely slow.
    @Test("Two passes over an unchanged store agree on every name")
    func namesAreStable() throws {
        let (context, kid) = try seeded()
        let favorite = try #require(kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B"))
        let playlist = kid.addPlaylist(named: "Car songs")
        _ = playlist.addSong(id: CatalogID(.song, "c"), displayName: "C")
        try context.save()

        // Detached by hand, which is exactly the shape an older build left on
        // disk. `context.save()` keeps them: nulling an inverse is not a delete.
        favorite.kid = nil
        try context.save()

        let first = try Outbox.pending(in: context).compactMap(\.recordName).sorted()
        let second = try Outbox.pending(in: context).compactMap(\.recordName).sorted()

        #expect(first == second)
    }

    /// And the consequence, stated as the thing a person would notice: the
    /// number next to "Sync now" reaches zero and stays there.
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

    /// The marks table is where the unbounded growth showed up first — one new
    /// mark per orphan per sync, forever, on the device rather than the server.
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

    /// Holding orphans back must not hold anything else back — the failure that
    /// would trade a growing zone for a child's playlist never arriving.
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

    /// **The tombstone is what reaches the other device.** Without it the
    /// favourite stays on a co-parent's phone forever, which is the failure
    /// `PendingDeletionRecord` documents and did not prevent, because nothing
    /// ever constructed one.
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

    /// A playlist's songs go with it. Cascade fires when the *kid* goes, not
    /// when a playlist leaves the array, so deleting only the playlist would
    /// leave every song in it orphaned.
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

    /// A removal followed by a sync has to settle, which is the whole point of
    /// both halves being here.
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
    /// The rows are unreachable by every query in the store — each one is
    /// `kid?.id == kidID` or the equivalent — so this deletes nothing anybody
    /// could see, and finishes a removal the parent already asked for.
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

    /// **A retracted entry is not an orphan.** It is still the kid's, still
    /// syncs, and is exactly the row a co-parent needs in order to learn that
    /// the deny was withdrawn — reaping it would resurrect the deny on their
    /// device.
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
