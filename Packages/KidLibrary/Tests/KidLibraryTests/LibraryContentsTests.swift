import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import KidLibrary

// MARK: - What the browser reads

@Suite("Browsing the library")
@MainActor
struct BrowsingTheLibrary {
    @Test("Hearting a song puts its record and its artist in the columns above it")
    func songFillsTheColumns() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        let contents = await harness.library.contents()
        #expect(contents.songs.map(\.id) == [Fix.clean])
        #expect(contents.albums.map(\.title) == ["The Record"])
        #expect(contents.artists.map(\.title) == ["Café Band"])
    }

    /// Tests the fold needs no catalog — not the rating rule, which predates this.
    @Test("Lineage is written at insert, so the columns need no catalog to draw")
    func columnsDrawOffline() async throws {
        let harness = try Harness(mode: .reportOnly)
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        // Everything the columns need was copied onto the row at heart time.
        harness.catalog.isFailing = true

        let contents = await harness.library.contents()
        #expect(contents.isResolved == false)
        #expect(contents.albums.map(\.title) == ["The Record"])
        #expect(contents.artists.map(\.title) == ["Café Band"])
    }

    @Test("Unhearting the last song on a record takes the record with it")
    func lastSongLeaves() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try await harness.library.addFavorite(Fix.item(Fix.other))

        try await harness.library.removeFavorite(Fix.clean)
        #expect(await harness.library.contents().albums.count == 1)

        try await harness.library.removeFavorite(Fix.other)
        let contents = await harness.library.contents()
        #expect(contents.albums.isEmpty)
        #expect(contents.artists.isEmpty)
    }

    @Test("A hearted record survives its last song being unhearted")
    func heartedRecordStays() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.record))
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        try await harness.library.removeFavorite(Fix.clean)

        let contents = await harness.library.contents()
        #expect(contents.songs.isEmpty)
        // The kid kept the record itself; unhearting a song doesn't touch that.
        #expect(contents.albums.map(\.title) == ["The Record"])
    }

    @Test("A record is one row whether it was hearted, folded, or both")
    func noDuplicateRow() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.record))
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        let contents = await harness.library.contents()
        #expect(contents.albums.count == 1)
        // The hearted one, which knows its rating.
        #expect(contents.albums.first?.rating == .clean)
    }

    @Test("Playlist entries fill the columns exactly like favorites do")
    func playlistEntriesCount() async throws {
        let harness = try Harness()
        let row = try await harness.library.createPlaylist(
            named: "Car rides",
            songs: [Fix.item(Fix.ballad)]
        )
        #expect(row.entries.count == 1)

        let contents = await harness.library.contents()
        #expect(contents.songs.map(\.id) == [Fix.ballad])
        #expect(contents.albums.map(\.title) == ["Antics"])
        #expect(contents.artists.map(\.title) == ["The Duo"])
    }

    @Test("A song kept twice — hearted and on a playlist — is one row")
    func dedupedAcrossTables() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try await harness.library.createPlaylist(named: "Both", songs: [Fix.item(Fix.clean)])

        #expect(await harness.library.contents().songs.count == 1)
    }

    @Test("Two acts stay apart, and each column is alphabetical")
    func twoActs() async throws {
        let harness = try Harness()
        for id in [Fix.clean, Fix.ballad] {
            try await harness.library.addFavorite(Fix.item(id))
        }

        let contents = await harness.library.contents()
        // "Antics" before "The Record", which files under R.
        #expect(contents.albums.map(\.title) == ["Antics", "The Record"])
        // "Café Band" under C, "The Duo" under D — the accent doesn't decide.
        #expect(contents.artists.map(\.title) == ["Café Band", "The Duo"])
    }

    @Test("An empty library is an empty answer, not a request")
    func emptyIsCheap() async throws {
        let harness = try Harness()
        harness.catalog.isFailing = true
        let contents = await harness.library.contents()
        #expect(contents.songs.isEmpty)
        #expect(contents.isResolved)
    }
}

// MARK: - The engine still decides

@Suite("The browser is not a way around the engine")
@MainActor
struct TheBrowserObeysTheEngine {
    @Test("A denied artist empties every column they were in")
    func deniedArtistDisappears() async throws {
        var harness = try Harness()
        for id in [Fix.clean, Fix.ballad] {
            try await harness.library.addFavorite(Fix.item(id))
        }
        #expect(await harness.library.contents().artists.count == 2)

        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.band, displayName: "band") }

        let contents = await harness.library.contents()
        #expect(contents.songs.map(\.id) == [Fix.ballad])
        #expect(contents.artists.map(\.title) == ["The Duo"])
        #expect(contents.albums.map(\.title) == ["Antics"])
        // Kept, never dropped: the report is built from these.
        #expect(contents.blocked.map(\.item.id) == [Fix.clean])
    }

    @Test("A denied record leaves its artist standing if another record survives")
    func deniedAlbumOnly() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try await harness.library.addFavorite(Fix.item(Fix.ballad))

        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.record, displayName: "record") }

        let contents = await harness.library.contents()
        #expect(contents.albums.map(\.title) == ["Antics"])
        #expect(contents.artists.map(\.title) == ["The Duo"])
    }

    @Test("A record whose only kept song is blocked contributes no row")
    func blockedSongFoldsToNothing() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.clean, displayName: "song") }

        let contents = await harness.library.contents()
        #expect(contents.songs.isEmpty)
        // Fold runs over survivors; nothing's left once the song is gone.
        #expect(contents.albums.isEmpty)
        #expect(contents.artists.isEmpty)
    }

    @Test("A level 1 kid sees the record their allowed song is on")
    func allowOnlyStillFolds() async throws {
        let harness = try Harness(
            mode: .allowOnly,
            entries: [.allow(Fix.clean)]
        )
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        let contents = await harness.library.contents()
        // Album isn't on the allow list — it's a folder over a song that is.
        #expect(contents.songs.map(\.id) == [Fix.clean])
        #expect(contents.albums.map(\.title) == ["The Record"])
    }
}

// MARK: - Catching up

@Suite("Rows written before lineage was stored")
@MainActor
struct TopUp {
    /// A favorite written straight to the store — name and artwork, no lineage.
    private func writeBareRow(_ harness: Harness, _ id: CatalogID) throws {
        harness.kid.addFavorite(id: id, displayName: "Sunshine", at: Fix.t0)
        try harness.context.save()
    }

    @Test("A row with no lineage is topped up on the first read that needs it")
    func topsUp() async throws {
        let harness = try Harness()
        try writeBareRow(harness, Fix.clean)

        // Nothing was stored, so nothing could be folded from it.
        #expect(harness.kid.favorites.first?.ancestry.isEmpty == true)

        let contents = await harness.library.contents()
        #expect(contents.albums.map(\.title) == ["The Record"])
        #expect(contents.artists.map(\.title) == ["Café Band"])

        // And it was written back, so the next read costs one request, not two.
        #expect(harness.kid.favorites.first?.albumName == "The Record")
        #expect(harness.kid.favorites.first?.artistName == "Café Band")
    }

    @Test("Once topped up, the columns survive the catalog going away")
    func topUpIsDurable() async throws {
        let harness = try Harness(mode: .reportOnly)
        try writeBareRow(harness, Fix.clean)
        _ = await harness.library.contents()

        harness.catalog.isFailing = true
        #expect(await harness.library.contents().albums.map(\.title) == ["The Record"])
    }

    @Test("An artist favorite is never a row waiting to be filled")
    func artistsAreNotCandidates() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))

        let contents = await harness.library.contents()
        #expect(contents.artists.map(\.title) == ["Café Band"])
        // An artist has no ancestors; reading that as unfilled would ask forever.
        #expect(harness.kid.favorites.first?.ancestry.isEmpty == true)
    }

    @Test("A catalog that will not answer leaves the row alone and tries again")
    func topUpIsBestEffort() async throws {
        let harness = try Harness()
        try writeBareRow(harness, Fix.clean)

        harness.catalog.isFailing = true
        #expect(await harness.library.contents().albums.isEmpty)

        harness.catalog.isFailing = false
        #expect(await harness.library.contents().albums.map(\.title) == ["The Record"])
    }
}

// MARK: - Insert-time capture

@Suite("Lineage is captured when the kid keeps something")
@MainActor
struct CapturingLineage {
    @Test("Hearting a song stores its record and artist by name")
    func storedOnTheRow() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        let row = try #require(harness.kid.favorites.first)
        #expect(row.albumID == Fix.record.rawValue)
        #expect(row.albumName == "The Record")
        #expect(row.artistID == Fix.band.rawValue)
        #expect(row.artistName == "Café Band")
    }

    @Test("A song added to a playlist stores it too")
    func storedOnPlaylistEntries() async throws {
        let harness = try Harness()
        let row = try await harness.library.createPlaylist(named: "Mix")
        try await harness.library.addToPlaylist(row.handle, song: Fix.item(Fix.clean))

        let entry = try #require(harness.kid.playlists.first?.entries.first)
        #expect(entry.albumName == "The Record")
        #expect(entry.artistName == "Café Band")
    }

    @Test("A heart still fills when the catalog cannot name the lineage")
    func writeSurvivesAFailedNaming() async throws {
        let harness = try Harness()
        // Lineage's already there; naming needs the net, hearting doesn't wait.
        let item = Fix.item(Fix.clean)
        harness.catalog.isFailing = true

        try await harness.library.addFavorite(item)

        #expect(await harness.library.favoriteIDs() == [Fix.clean])
        #expect(harness.kid.favorites.first?.ancestry.isEmpty == true)
    }

    @Test("A second heart while offline does not wipe the lineage already stored")
    func refreshNeverDowngrades() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        #expect(harness.kid.favorites.first?.albumName == "The Record")

        harness.catalog.isFailing = true
        try? await harness.library.addFavorite(Fix.item(Fix.clean))

        #expect(harness.kid.favorites.first?.albumName == "The Record")
    }
}
