import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import KidLibrary

// MARK: - Walking down

@Suite("Keeping an artist keeps their work")
@MainActor
struct WalkingDown {
    @Test("Hearting an artist indexes every record and every track on them")
    func artistBringsTheTree() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        let contents = await harness.library.contents()
        #expect(contents.albums.map(\.title) == ["The Record"])
        // Four tracks were indexed and two of them are drawable. The walk records
        // what the catalog said — explicit and unrated alike — and the engine has
        // its say afterwards, which is what lets a parent's edit reach a library
        // indexed weeks ago.
        #expect(contents.songs.count == 2)
        #expect(Set(contents.blocked.map(\.item.id)) == [Fix.explicit, Fix.unrated])
    }

    @Test("Hearting a record indexes its tracks and stops there")
    func albumBringsItsTracks() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.record))
        await harness.library.expand(Fix.item(Fix.record))

        let contents = await harness.library.contents()
        #expect(contents.songs.count == 2)
        // One walk of the record's tracks. An artist would have cost one for the
        // records and one more per record.
        #expect(harness.catalog.childrenCalls == 1)
    }

    @Test("Hearting a song walks nothing")
    func songWalksNothing() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        await harness.library.expand(Fix.item(Fix.clean))

        #expect(harness.catalog.childrenCalls == 0)
        #expect(await harness.library.contents().songs.count == 1)
    }

    @Test("An indexed track carries the lineage that puts it under its record")
    func indexedTracksAreReachable() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        let contents = await harness.library.contents()
        let onTheRecord = LibraryBrowse.songs(from: contents.songs, on: Fix.record)
        // "Nobody Rated This" is absent, not missing: `UnratedBehavior.block` is
        // the default and it never reached the fold.
        #expect(onTheRecord.map(\.title) == ["Sunshine", "Something Else"])

        let byTheBand = LibraryBrowse.albums(from: contents.songs, by: Fix.band)
        #expect(byTheBand.map(\.title) == ["The Record"])
    }

    @Test("Indexed tracks come back in track order, not in catalog order")
    func trackOrder() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.record))
        await harness.library.expand(Fix.item(Fix.record))

        let songs = LibraryBrowse.songs(
            from: await harness.library.contents().songs,
            on: Fix.record
        )
        #expect(songs.compactMap(\.trackNumber) == [1, 4])
    }

    @Test("A record with no artwork of its own borrows the artist's cover for its tracks")
    func tracksBorrowArtwork() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.record))
        await harness.library.expand(Fix.item(Fix.record))

        // The fixture's tracks carry no artwork. Every one of them should still
        // draw something rather than a column of grey squares.
        let songs = await harness.library.contents().songs
        #expect(songs.allSatisfy { $0.item.artworkURL == Fix.item(Fix.record).artworkURL })
    }
}

// MARK: - What the Songs column holds

@Suite("Chosen songs and indexed ones are different lists")
@MainActor
struct ChosenSongs {
    @Test("An artist's tracks are in the library but not in the Songs column")
    func indexedIsNotChosen() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        let contents = await harness.library.contents()
        // In the library, and reachable by opening the artist or the record.
        #expect(contents.songItems.count == 2)
        // Not in the column a kid scans for what they picked out.
        #expect(contents.chosenSongItems.isEmpty)
    }

    @Test("A hearted song is chosen, and stays chosen when its artist is kept too")
    func heartedStaysChosen() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        let contents = await harness.library.contents()
        #expect(contents.songItems.count == 2)
        // The walk indexed this song as well, and the hand-picked row wins the
        // duplicate — so keeping the artist does not quietly demote it.
        #expect(contents.chosenSongItems.map(\.id) == [Fix.clean])
    }

    @Test("A song on the kid's own playlist counts as chosen")
    func playlistEntriesAreChosen() async throws {
        let harness = try Harness()
        try await harness.library.createPlaylist(named: "Mix", songs: [Fix.item(Fix.other)])
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        #expect(await harness.library.contents().chosenSongItems.map(\.id) == [Fix.other])
    }

    @Test("Drilling in still shows everything, which is the point of the split")
    func drillInIsUnaffected() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        let contents = await harness.library.contents()
        #expect(LibraryBrowse.songs(from: contents.songs, on: Fix.record).count == 2)
        #expect(LibraryBrowse.songs(from: contents.songs, by: Fix.band).count == 2)
        #expect(LibraryBrowse.albums(contents.albums, by: Fix.band).map(\.title) == ["The Record"])
    }

    @Test("An artist's records are in the library but not in the Albums column")
    func indexedAlbumsAreNotChosen() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        let contents = await harness.library.contents()
        #expect(contents.albums.map(\.title) == ["The Record"])
        #expect(contents.chosenAlbums.isEmpty)
    }

    @Test("A record hearted on its own is chosen; so is one a hearted song sits on")
    func chosenAlbumsAreWhatWasPointedAt() async throws {
        let hearted = try Harness()
        try await hearted.library.addFavorite(Fix.item(Fix.record))
        #expect(await hearted.library.contents().chosenAlbums.map(\.title) == ["The Record"])

        // Hearting a song has put its record on this list since before walks
        // existed, and that is a fact about the song the kid picked.
        let viaSong = try Harness()
        try await viaSong.library.addFavorite(Fix.item(Fix.clean))
        #expect(await viaSong.library.contents().chosenAlbums.map(\.title) == ["The Record"])
    }

    @Test("A record a walk indexed but could not fill is still under its artist")
    func trackless() async throws {
        let harness = try Harness()
        harness.catalog.breakChildren(of: Fix.record)
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        let contents = await harness.library.contents()
        #expect(contents.songs.isEmpty)
        // Nothing can fold it out of a song, because there is no song. Reading
        // the album list rather than folding is what keeps it reachable.
        #expect(LibraryBrowse.albums(contents.albums, by: Fix.band).map(\.title) == ["The Record"])
    }
}

// MARK: - Cost

@Suite("The walk happens once, not on every read")
@MainActor
struct WalkedOnce {
    @Test("Reading the library never walks")
    func readsAreFree() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))
        let afterWalk = harness.catalog.childrenCalls

        for _ in 0..<5 { _ = await harness.library.contents() }

        // The whole reason the index exists: an artist is fifty round trips and
        // opening the library is none of them.
        #expect(harness.catalog.childrenCalls == afterWalk)
    }

    @Test("An indexed row is judged without asking the catalog anything")
    func judgingIsLocal() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        // The rating and the lineage were stored when the walk ran, which is
        // everything a verdict needs.
        harness.catalog.isFailing = true

        let contents = await harness.library.contents()
        #expect(contents.songs.count == 2)
        #expect(Set(contents.blocked.map(\.item.id)) == [Fix.explicit, Fix.unrated])
    }

    @Test("A source already walked says so, so a caller can skip it")
    func knowsWhatItHasWalked() async throws {
        let harness = try Harness()
        #expect(await harness.library.isIndexed(Fix.band) == false)

        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        #expect(await harness.library.isIndexed(Fix.band))
    }

    @Test("Walking twice adds nothing the second time")
    func idempotent() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))
        let first = await harness.library.contents().songs.count

        await harness.library.expand(Fix.item(Fix.band))

        #expect(await harness.library.contents().songs.count == first)
    }
}

// MARK: - Partial walks

@Suite("A walk that does not finish")
@MainActor
struct PartialWalks {
    @Test("One record failing costs that record, not the artist")
    func oneFailureIsNotTheWalk() async throws {
        let harness = try Harness()
        harness.catalog.breakChildren(of: Fix.sophomore)
        try await harness.library.addFavorite(Fix.item(Fix.duo))
        await harness.library.expand(Fix.item(Fix.duo))

        let contents = await harness.library.contents()
        // The record itself came back with the artist's first request and is
        // still browsable; only its tracks are missing.
        #expect(contents.albums.map(\.title) == ["Antics"])
        #expect(contents.songs.isEmpty)
    }

    @Test("What a half-finished walk got is kept, and the rest arrives later")
    func writesAsItGoes() async throws {
        let harness = try Harness()
        harness.catalog.breakChildren(of: Fix.record)
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        #expect(await harness.library.contents().albums.map(\.title) == ["The Record"])
        #expect(await harness.library.contents().songs.isEmpty)

        // Nothing had to be undone for the retry to work: the walk adds what is
        // missing rather than starting from nothing.
        harness.catalog.fixChildren(of: Fix.record)
        await harness.library.expand(Fix.item(Fix.band))

        #expect(await harness.library.contents().songs.count == 2)
    }

    @Test("A catalog that will not answer at all indexes nothing and is not an error")
    func offlineWalkIsSilent() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        harness.catalog.isFailing = true

        await harness.library.expand(Fix.item(Fix.band))

        #expect(await harness.library.isIndexed(Fix.band) == false)
    }
}

// MARK: - Lifetime

@Suite("What the index goes with")
@MainActor
struct IndexLifetime {
    @Test("Unhearting the artist takes their whole tree with it")
    func removalTakesTheTree() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))
        #expect(await harness.library.contents().songs.count == 2)

        try await harness.library.removeFavorite(Fix.band)

        let contents = await harness.library.contents()
        #expect(contents.songs.isEmpty)
        #expect(contents.albums.isEmpty)
        #expect(contents.artists.isEmpty)
    }

    @Test("A song hearted on its own outlives the artist that also brought it in")
    func handPickedSurvives() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        try await harness.library.removeFavorite(Fix.band)

        #expect(await harness.library.contents().songs.map(\.id) == [Fix.clean])
    }

    @Test("Two kept things sharing a record each keep their own copy of it")
    func sourcesAreIndependent() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        try await harness.library.addFavorite(Fix.item(Fix.record))
        await harness.library.expand(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.record))

        // One row on screen, from two sources underneath.
        #expect(await harness.library.contents().songs.count == 2)

        try await harness.library.removeFavorite(Fix.band)

        // The record is still kept, so its tracks are still here.
        #expect(await harness.library.contents().songs.count == 2)
    }

    @Test("The index is not history and survives clearing the logs")
    func survivesDeleteHistory() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        harness.kid.deleteHistory()
        try harness.context.save()

        // A parent clearing a month of logs is not asking for their child's
        // library to shrink. Favorites and playlists already worked this way;
        // being derived does not change what this follows.
        #expect(await harness.library.contents().songs.count == 2)
    }

    @Test("Wiping everything takes it")
    func goesWithDeleteEverything() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        harness.kid.deleteEverything()
        try harness.context.save()

        #expect(await harness.library.contents().songs.isEmpty)
    }
}

// MARK: - The engine still decides

@Suite("An indexed row is not a permission")
@MainActor
struct IndexIsNotAPermission {
    @Test("Denying the artist after the walk empties the library it filled")
    func denyReachesIndexedRows() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))
        #expect(await harness.library.contents().songs.count == 2)

        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.band, displayName: "band") }

        let contents = await harness.library.contents()
        #expect(contents.songs.isEmpty)
        #expect(contents.albums.isEmpty)
    }

    @Test("A level 1 kid keeps the index and loses it with the allow list")
    func allowOnlyStillCloses() async throws {
        var harness = try Harness(mode: .allowOnly, entries: [.allow(Fix.band)])
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        // The artist is on the list, so what is under them is reachable — which
        // is what `allowOnly` means, not something the index decided.
        #expect(await harness.library.contents().songs.isEmpty == false)

        // Taking the artist off the list closes it again, with every row still
        // sitting in the index. Being indexed is not being allowed.
        try harness.repolicy { $0.removeEntry($0.entries[0]) }
        #expect(await harness.library.contents().songs.isEmpty)
    }

    @Test("An indexed row never fills a heart")
    func indexedIsNotHearted() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.band))
        await harness.library.expand(Fix.item(Fix.band))

        // The kid kept the artist. They did not keep three songs, and three
        // hearts filling in behind them would say they had.
        #expect(await harness.library.favoriteIDs() == [Fix.band])
    }
}
