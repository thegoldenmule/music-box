import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

// MARK: - Fixtures

private enum Fix {
    static let artist = CatalogID(.artist, "artist-A")
    static let album = CatalogID(.album, "album-A")
    static let song = CatalogID(.song, "song-A")
    static let song2 = CatalogID(.song, "song-B")
    static let song3 = CatalogID(.song, "song-C")
    static let catalogPlaylist = CatalogID(.playlist, "playlist-A")

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_700_086_400)
    static let t2 = Date(timeIntervalSince1970: 1_700_172_800)
}

@MainActor
private func newKid() throws -> (ModelContext, Kid) {
    let context = ModelContext(try FamilyStore.inMemoryContainer())
    let family = Family(at: Fix.t0)
    let kid = Kid(name: "Robin", mode: .denyPlusAuto, at: Fix.t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.t0)
    return (context, kid)
}

// MARK: - Favorites

@Suite("Favorites")
@MainActor
struct Favorites {
    @Test("A favorite round-trips through storage as a row")
    func roundTrips() throws {
        let (context, kid) = try newKid()
        kid.addFavorite(
            id: Fix.album,
            displayName: "An Album",
            artworkURL: URL(string: "https://example.invalid/a.jpg"),
            at: Fix.t0
        )
        try context.save()

        let row = try #require(kid.favorites.first?.row)
        #expect(row.catalogID == Fix.album)
        #expect(row.displayName == "An Album")
        #expect(row.favoritedAt == Fix.t0)
        #expect(row.origin == .kid)
    }

    @Test("The same favorite twice is one row, not two")
    func upserts() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "A Song", at: Fix.t0)
        kid.addFavorite(id: Fix.song, displayName: "A Song, renamed", at: Fix.t1)

        #expect(kid.favorites.count == 1)
        #expect(kid.favorites.first?.displayName == "A Song, renamed")
    }

    @Test("Re-favoriting does not move the item to the front of the shelf")
    func favoritedAtHolds() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "A Song", at: Fix.t0)
        kid.addFavorite(id: Fix.song, displayName: "A Song", at: Fix.t1)

        #expect(kid.favorites.first?.favoritedAt == Fix.t0)
    }

    @Test("An adopted row that the kid then taps becomes theirs, and not back")
    func originOnlyEverStrengthens() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "A Song", origin: .appleLibrary, at: Fix.t0)
        #expect(kid.favorites.first?.libraryOrigin == .appleLibrary)

        kid.addFavorite(id: Fix.song, displayName: "A Song", origin: .kid, at: Fix.t1)
        #expect(kid.favorites.first?.libraryOrigin == .kid)

        // A later adoption pass must not take the kid's own choice back off them.
        kid.addFavorite(id: Fix.song, displayName: "A Song", origin: .appleLibrary, at: Fix.t2)
        #expect(kid.favorites.first?.libraryOrigin == .kid)
    }

    @Test("The same identifier as two kinds is two favorites")
    func kindIsPartOfIdentity() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: CatalogID(.song, "X"), displayName: "Song X", at: Fix.t0)
        kid.addFavorite(id: CatalogID(.album, "X"), displayName: "Album X", at: Fix.t0)

        #expect(kid.favorites.count == 2)

        kid.removeFavorite(CatalogID(.song, "X"))
        #expect(kid.favorites.count == 1)
        #expect(kid.favorites.first?.itemID == CatalogID(.album, "X"))
    }

    @Test("A playlist cannot be favorited — it is owned, not marked")
    func playlistsAreNotFavoritable() throws {
        let (_, kid) = try newKid()
        #expect(kid.addFavorite(id: Fix.catalogPlaylist, displayName: "Somebody's mix") == nil)
        #expect(kid.favorites.isEmpty)
    }

    @Test("Removing takes every row for the item, not just the first")
    func removesEveryRow() throws {
        let (context, kid) = try newKid()
        // Two rows for one item is not reachable through `addFavorite`, but the
        // schema permits it — CloudKit rejects unique constraints — so a sync
        // merge could produce one.
        for _ in 0..<2 {
            let record = FavoriteRecord(catalogID: Fix.song, displayName: "A Song", at: Fix.t0)
            context.insert(record)
            kid.attach(record)
        }
        #expect(kid.favorites.count == 2)

        kid.removeFavorite(Fix.song)
        #expect(kid.favorites.isEmpty)
    }

    @Test("A row with an unreadable kind is dropped rather than guessed at")
    func unreadableKindIsDropped() {
        let record = FavoriteRecord(
            rawItemKind: "sculpture",
            catalogID: "X",
            displayName: "A Statue",
            at: Fix.t0
        )
        #expect(record.itemID == nil)
        #expect(record.row == nil)
    }

    @Test("A row with an unreadable origin is dropped too")
    func unreadableOriginIsDropped() {
        let record = FavoriteRecord(
            rawItemKind: ItemKind.song.rawValue,
            catalogID: "X",
            displayName: "A Song",
            rawOrigin: "telepathy",
            at: Fix.t0
        )
        #expect(record.row == nil)
    }

    @Test("Deleting history leaves the library alone")
    func historyDeletionSparesTheLibrary() throws {
        let (context, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "A Song", at: Fix.t0)
        kid.addPlaylist(named: "Bangers", at: Fix.t0)
        try context.save()

        kid.deleteHistory(at: Fix.t1)

        #expect(kid.favorites.count == 1)
        #expect(kid.playlists.count == 1)
    }

    @Test("Favoriting does not churn the record sync watches")
    func doesNotStampTheKid() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "A Song", at: Fix.t1)
        #expect(kid.modifiedAt == Fix.t0)
    }
}

// MARK: - Playlists

@Suite("Playlists")
@MainActor
struct Playlists {
    @Test("A playlist round-trips with its songs in order")
    func roundTrips() throws {
        let (context, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Bangers", at: Fix.t0)
        playlist.addSong(id: Fix.song, displayName: "One", at: Fix.t0)
        playlist.addSong(id: Fix.song2, displayName: "Two", at: Fix.t1)
        try context.save()

        let row = playlist.row
        #expect(row.name == "Bangers")
        #expect(row.entries.map(\.catalogID) == [Fix.song, Fix.song2])
        // The *order*, not the numbers. Positions are sparse now so that
        // appending never rewrites a neighbour — see `PlaylistRecord.positionGap`.
        #expect(row.entries.map(\.position) == row.entries.map(\.position).sorted())
        #expect(row.handle.local == playlist.id)
        #expect(row.handle.appleLibraryID == nil)
        #expect(row.appleIsOurs == false)
    }

    @Test("Only songs go in a playlist")
    func onlySongs() throws {
        let (_, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Bangers", at: Fix.t0)

        #expect(playlist.addSong(id: Fix.album, displayName: "An Album") == nil)
        #expect(playlist.addSong(id: Fix.artist, displayName: "A Band") == nil)
        #expect(playlist.entries.isEmpty)
    }

    @Test("Adding a song already there changes nothing and is not an error")
    func addingTwiceIsQuiet() throws {
        let (_, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Bangers", at: Fix.t0)
        playlist.addSong(id: Fix.song, displayName: "One", at: Fix.t0)

        #expect(playlist.addSong(id: Fix.song, displayName: "One", at: Fix.t1) == nil)
        #expect(playlist.entries.count == 1)
    }

    /// Was "positions stay contiguous". They do not any more, and that is the
    /// fix rather than a regression: renumbering ran only on the editing device,
    /// so after a merge the list held two entries in one slot and a hole nothing
    /// repaired — and it rewrote `modifiedAt` on every row on every edit, on the
    /// records with the most of a child's own work in them.
    @Test("A removal from the middle leaves the rest in order")
    func removalKeepsOrder() throws {
        let (_, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Bangers", at: Fix.t0)
        playlist.addSong(id: Fix.song, displayName: "One", at: Fix.t0)
        playlist.addSong(id: Fix.song2, displayName: "Two", at: Fix.t0)
        playlist.addSong(id: Fix.song3, displayName: "Three", at: Fix.t0)

        playlist.removeSong(Fix.song2, at: Fix.t1)

        #expect(playlist.row.entries.map(\.catalogID) == [Fix.song, Fix.song3])
        // A hole is a supported state now.
        #expect(playlist.row.entries.map(\.position) == playlist.row.entries.map(\.position).sorted())
    }

    @Test("Reordering to a new sequence redistributes with room between")
    func reorders() throws {
        let (_, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Bangers", at: Fix.t0)
        playlist.addSong(id: Fix.song, displayName: "One", at: Fix.t0)
        playlist.addSong(id: Fix.song2, displayName: "Two", at: Fix.t0)
        playlist.addSong(id: Fix.song3, displayName: "Three", at: Fix.t0)

        playlist.reorder(to: [Fix.song3, Fix.song, Fix.song2], at: Fix.t1)

        #expect(playlist.row.entries.map(\.catalogID) == [Fix.song3, Fix.song, Fix.song2])
        // Redistributed from zero in gaps, so something can be dropped between
        // any two of them later without touching either.
        let gap = PlaylistRecord.positionGap
        #expect(playlist.row.entries.map(\.position) == [0, gap, gap * 2])
    }

    @Test("A partial order is a reorder, not a deletion")
    func partialReorderKeepsEverything() throws {
        let (_, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Bangers", at: Fix.t0)
        playlist.addSong(id: Fix.song, displayName: "One", at: Fix.t0)
        playlist.addSong(id: Fix.song2, displayName: "Two", at: Fix.t0)
        playlist.addSong(id: Fix.song3, displayName: "Three", at: Fix.t0)

        // As if a removal on another screen raced the drag.
        playlist.reorder(to: [Fix.song3], at: Fix.t1)

        #expect(playlist.row.entries.map(\.catalogID) == [Fix.song3, Fix.song, Fix.song2])
        #expect(playlist.row.entries.count == 3)
    }

    @Test("The Apple counterpart is recorded as one fact, at creation")
    func linksToApple() throws {
        let (_, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Bangers", at: Fix.t0)
        playlist.linkToAppleLibrary(id: "p.abc123", createdByUs: true, at: Fix.t1)

        #expect(playlist.handle.appleLibraryID == "p.abc123")
        #expect(playlist.appleIsOurs)
        #expect(playlist.modifiedAt == Fix.t1)
    }

    @Test("Deleting a playlist takes its entries with it")
    func deleteCascades() throws {
        let (context, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Bangers", at: Fix.t0)
        playlist.addSong(id: Fix.song, displayName: "One", at: Fix.t0)
        try context.save()

        kid.removePlaylist(playlist)
        context.delete(playlist)
        try context.save()

        #expect(kid.playlists.isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistEntryRecord>()).isEmpty)
    }

    @Test("Renaming stamps the playlist")
    func renameStamps() throws {
        let (_, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Bangers", at: Fix.t0)
        playlist.rename(to: "Bangers 2", at: Fix.t1)

        #expect(playlist.name == "Bangers 2")
        #expect(playlist.modifiedAt == Fix.t1)
    }
}

// MARK: - The origin column

@Suite("A kid's own playlist as a playback origin")
struct KidPlaylistOrigin {
    @Test("Round-trips through the stored columns")
    func roundTrips() {
        let local = UUID()
        let origin = PlaybackOrigin.kidPlaylist(local)
        #expect(PlaybackOrigin(stored: origin.stored) == origin)
    }

    @Test("Carries no item kind — the identifier is not the catalog's")
    func carriesNoKind() {
        #expect(PlaybackOrigin.kidPlaylist(UUID()).stored.kind == nil)
    }

    @Test("A local identifier that will not parse reads back as nothing")
    func refusesRubbish() {
        let stored = StoredOrigin(name: PlaybackOrigin.Name.kidPlaylist, id: "not-a-uuid")
        #expect(PlaybackOrigin(stored: stored) == nil)
    }
}

// MARK: - Ancestry

@Suite("Lineage on a stored row")
@MainActor
struct StoredLineage {
    private let lineage = LibraryAncestry(
        albumID: "album-A",
        albumName: "The Record",
        artistID: "artist-A",
        artistName: "Café Band",
        artistArtworkURL: URL(string: "https://example.invalid/a.jpg")
    )

    @Test("Round-trips through the five columns, on a favorite and on an entry")
    func roundTrips() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "Sunshine", ancestry: lineage, at: Fix.t0)
        let playlist = kid.addPlaylist(named: "Mix", at: Fix.t0)
        playlist.addSong(id: Fix.song, displayName: "Sunshine", ancestry: lineage, at: Fix.t0)

        #expect(kid.favorites.first?.row?.ancestry == lineage)
        #expect(playlist.row.entries.first?.ancestry == lineage)
    }

    @Test("Absent by default, and that is a supported state rather than a broken row")
    func defaultsToNothing() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "Sunshine", at: Fix.t0)

        let row = try #require(kid.favorites.first?.row)
        #expect(row.ancestry == .none)
        #expect(row.ancestry.isEmpty)
        // Everything else about the row still reads.
        #expect(row.displayName == "Sunshine")
    }

    @Test("An identifier alone does not count as recorded")
    func idWithoutNameIsEmpty() {
        // What the top-up looks for. A row holding identifiers it cannot name
        // draws nothing, so it has to stay a candidate.
        #expect(LibraryAncestry(albumName: "The Record").isEmpty)
        #expect(LibraryAncestry(albumID: "album-A").isEmpty == false)
    }

    @Test("Typed identifiers are built from the stored strings")
    func typedIdentifiers() {
        #expect(lineage.album == CatalogID(.album, "album-A"))
        #expect(lineage.artist == CatalogID(.artist, "artist-A"))
        #expect(LibraryAncestry.none.album == nil)
    }

    @Test("A second tap while offline does not erase lineage already stored")
    func refreshNeverDowngrades() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "Sunshine", ancestry: lineage, at: Fix.t0)
        kid.addFavorite(id: Fix.song, displayName: "Sunshine", at: Fix.t1)

        #expect(kid.favorites.first?.ancestry == lineage)
    }

    @Test("Catching up records lineage without touching the copied metadata")
    func recordLeavesTheNameAlone() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "Sunshine", at: Fix.t0)

        let record = try #require(kid.favorites.first)
        record.record(ancestry: lineage, at: Fix.t1)

        #expect(record.ancestry == lineage)
        // The name on the row is what the kid saw when they kept it, and a
        // top-up is not a second tap.
        #expect(record.displayName == "Sunshine")
        #expect(record.favoritedAt == Fix.t0)
        #expect(record.modifiedAt == Fix.t1)
    }

    @Test("Recording nothing is not a write")
    func recordingNothingIsNoop() throws {
        let (_, kid) = try newKid()
        kid.addFavorite(id: Fix.song, displayName: "Sunshine", ancestry: lineage, at: Fix.t0)

        let record = try #require(kid.favorites.first)
        record.record(ancestry: .none, at: Fix.t1)

        #expect(record.ancestry == lineage)
        #expect(record.modifiedAt == Fix.t0)
    }
}
