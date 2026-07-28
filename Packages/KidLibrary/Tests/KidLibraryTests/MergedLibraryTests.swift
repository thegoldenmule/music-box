import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import KidLibrary

// MARK: - Favorites

@Suite("Favoriting")
@MainActor
struct Favoriting {
    @Test("A song, an album and an artist all favorite the same way")
    func everyKind() async throws {
        let harness = try Harness()
        for id in [Fix.clean, Fix.record, Fix.band] {
            try await harness.library.addFavorite(Fix.item(id))
        }

        let ids = await harness.library.favoriteIDs()
        #expect(ids == [Fix.clean, Fix.record, Fix.band])
    }

    @Test("The heart reads from rows in memory, without asking the catalog")
    func heartNeedsNoRequest() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        harness.catalog.isFailing = true

        #expect(await harness.library.favoriteIDs() == [Fix.clean])
    }

    @Test("An explicit song cannot be favorited")
    func refusesExplicit() async throws {
        let harness = try Harness()
        await #expect(throws: LibraryRefused.self) {
            try await harness.library.addFavorite(Fix.item(Fix.explicit))
        }
        #expect(await harness.library.favoriteIDs().isEmpty)
    }

    @Test("The refusal carries the reason, so the block can be reported")
    func refusalCarriesTheReason() async throws {
        let harness = try Harness(entries: [.deny(Fix.band)])
        do {
            try await harness.library.addFavorite(Fix.item(Fix.clean))
            Issue.record("Expected a refusal")
        } catch let refusal as LibraryRefused {
            #expect(refusal.reason == .deniedByParent(Fix.band))
            #expect(refusal.item.id == Fix.clean)
        }
    }

    @Test("A denied artist reaches a song that arrived without lineage")
    func resolvesAncestryBeforeJudging() async throws {
        let harness = try Harness(entries: [.deny(Fix.band)])
        // As a search result arrives: no album, no artist, nothing to judge
        // against until the lineage is fetched.
        await #expect(throws: LibraryRefused.self) {
            try await harness.library.addFavorite(Fix.bare(Fix.clean))
        }
    }

    @Test("A level 1 kid may only favorite what the parent put on the list")
    func allowOnly() async throws {
        let harness = try Harness(mode: .allowOnly, entries: [.allow(Fix.clean)])

        try await harness.library.addFavorite(Fix.item(Fix.clean))
        await #expect(throws: LibraryRefused.self) {
            try await harness.library.addFavorite(Fix.item(Fix.other))
        }
    }

    @Test("Unfavoriting is never refused, even for something now denied")
    func removalIsNeverRefused() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.band, displayName: "Café Band") }

        try await harness.library.removeFavorite(Fix.clean)
        #expect(await harness.library.favoriteIDs().isEmpty)
    }

    @Test("A playlist is owned, never favorited")
    func playlistsAreNotFavorites() async throws {
        let harness = try Harness(mode: .reportOnly)
        let playlist = CatalogItem(id: CatalogID(.playlist, "p1"), title: "Somebody's mix")

        try await harness.library.addFavorite(playlist)
        #expect(await harness.library.favoriteIDs().isEmpty)
    }
}

// MARK: - The render-time filter

@Suite("What a shelf shows")
@MainActor
struct TheShelf {
    @Test("A favorite denied since is off the shelf, and the row survives")
    func filteredAtRenderTime() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try await harness.library.addFavorite(Fix.item(Fix.other))

        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.clean, displayName: "Sunshine") }

        let shelf = try await harness.library.favorites()
        #expect(shelf.items.map(\.id) == [Fix.other])
        #expect(shelf.blocked.map(\.item.id) == [Fix.clean])

        // The row is still there. Widening the rule brings the tile back with
        // no re-favoriting, which is the whole point of not storing it filtered.
        #expect(harness.kid.favorites.count == 2)
    }

    @Test("Blocks are kept with their reasons, for the parent's report")
    func blocksAreKept() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.band, displayName: "Café Band") }

        let shelf = try await harness.library.favorites()
        #expect(shelf.blocked.first?.reason == .deniedByParent(Fix.band))
    }

    @Test("Most recent first")
    func ordering() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try await harness.library.addFavorite(Fix.item(Fix.other))

        let shelf = try await harness.library.favorites()
        #expect(shelf.items.map(\.id) == [Fix.other, Fix.clean])
    }

    @Test("A delisted favorite still reads as a name rather than an identifier")
    func delistedFallsBackToTheStoredCopy() async throws {
        let harness = try Harness(mode: .reportOnly)
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        harness.catalog.delist(Fix.clean)

        let shelf = try await harness.library.favorites()
        #expect(shelf.items.map(\.title) == ["Sunshine"])
    }
}

// MARK: - Offline

@Suite("A catalog that will not answer")
@MainActor
struct Offline {
    @Test("The shelf still renders, from the copies made at write time")
    func rendersOffline() async throws {
        let harness = try Harness(mode: .reportOnly)
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        harness.catalog.isFailing = true

        let shelf = try await harness.library.favorites()
        #expect(shelf.items.map(\.title) == ["Sunshine"])
        #expect(shelf.isResolved == false)
    }

    @Test("A deny still bites with no catalog to resolve against")
    func denyStillBites() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.clean, displayName: "Sunshine") }
        harness.catalog.isFailing = true

        let shelf = try await harness.library.favorites()
        #expect(shelf.items.isEmpty)
    }

    @Test("Level 1 fails closed offline; level 2's rating check fails open")
    func provisionalVerdictsCutBothWays() async throws {
        // Fails closed: nothing on the allow list, nothing on the shelf.
        var closed = try Harness(mode: .allowOnly, entries: [.allow(Fix.clean)])
        try await closed.library.addFavorite(Fix.item(Fix.clean))
        try closed.repolicy { $0.removeEntry($0.entries[0]) }
        closed.catalog.isFailing = true
        #expect(try await closed.library.favorites().items.isEmpty)

        // Fails open: the stored copy carries no rating, and `.block` therefore
        // has nothing to bite on. The player's re-check is what catches it.
        let open = try Harness(mode: .reportOnly)
        try await open.library.addFavorite(Fix.item(Fix.explicit))
        open.catalog.isFailing = true
        #expect(try await open.library.favorites().items.count == 1)
    }
}

// MARK: - Playlists

@Suite("Playlists")
@MainActor
struct Playlists {
    @Test("A playlist is made, added to, reordered and read back in order")
    func lifecycle() async throws {
        let harness = try Harness()
        let row = try await harness.library.createPlaylist(
            named: "Bangers",
            songs: [Fix.item(Fix.clean)]
        )
        try await harness.library.addToPlaylist(row.handle, song: Fix.item(Fix.other))

        var songs = try await harness.library.songs(in: row.handle)
        #expect(songs.items.map(\.id) == [Fix.clean, Fix.other])

        try await harness.library.reorderPlaylist(row.handle, to: [Fix.other, Fix.clean])
        songs = try await harness.library.songs(in: row.handle)
        #expect(songs.items.map(\.id) == [Fix.other, Fix.clean])

        try await harness.library.removeFromPlaylist(row.handle, song: Fix.other)
        songs = try await harness.library.songs(in: row.handle)
        #expect(songs.items.map(\.id) == [Fix.clean])
    }

    @Test("Renaming and deleting")
    func renameAndDelete() async throws {
        let harness = try Harness()
        let row = try await harness.library.createPlaylist(named: "Bangers")

        try await harness.library.renamePlaylist(row.handle, to: "Bangers 2")
        #expect(await harness.library.playlist(row.handle)?.name == "Bangers 2")

        try await harness.library.deletePlaylist(row.handle)
        #expect(await harness.library.playlists().isEmpty)
    }

    @Test("A blocked song is dropped from a new playlist, not refused")
    func blockedSongsAreDropped() async throws {
        let harness = try Harness()
        let row = try await harness.library.createPlaylist(
            named: "Bangers",
            songs: [Fix.item(Fix.clean), Fix.item(Fix.explicit)]
        )

        let songs = try await harness.library.songs(in: row.handle)
        #expect(songs.items.map(\.id) == [Fix.clean])
    }

    @Test("A playlist of nothing but blocked songs is refused")
    func nothingSurvivingIsARefusal() async throws {
        let harness = try Harness()
        await #expect(throws: LibraryRefused.self) {
            try await harness.library.createPlaylist(
                named: "Bangers",
                songs: [Fix.item(Fix.explicit)]
            )
        }
        #expect(await harness.library.playlists().isEmpty)
    }

    @Test("An empty playlist is fine — a kid names it before filling it")
    func emptyIsFine() async throws {
        let harness = try Harness()
        let row = try await harness.library.createPlaylist(named: "Bangers")
        #expect(row.entries.isEmpty)
        #expect(await harness.library.playlists().count == 1)
    }

    @Test("A song denied since is off the playlist and in the blocked half")
    func filteredAtRenderTime() async throws {
        var harness = try Harness()
        let row = try await harness.library.createPlaylist(
            named: "Bangers",
            songs: [Fix.item(Fix.clean), Fix.item(Fix.other)]
        )
        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.clean, displayName: "Sunshine") }

        let songs = try await harness.library.songs(in: row.handle)
        #expect(songs.items.map(\.id) == [Fix.other])
        #expect(songs.blocked.map(\.item.id) == [Fix.clean])
    }

    @Test("Only songs go in a playlist")
    func onlySongs() async throws {
        let harness = try Harness(mode: .reportOnly)
        let row = try await harness.library.createPlaylist(named: "Bangers")

        try await harness.library.addToPlaylist(row.handle, song: Fix.item(Fix.record))
        try await harness.library.addToPlaylist(row.handle, song: Fix.item(Fix.band))

        #expect(try await harness.library.songs(in: row.handle).items.isEmpty)
    }

    @Test("Adding a blocked song is refused")
    func refusesBlockedAdds() async throws {
        let harness = try Harness()
        let row = try await harness.library.createPlaylist(named: "Bangers")

        await #expect(throws: LibraryRefused.self) {
            try await harness.library.addToPlaylist(row.handle, song: Fix.item(Fix.explicit))
        }
    }

    @Test("Editing a playlist that is gone is an error, not a silent no-op")
    func unknownPlaylist() async throws {
        let harness = try Harness()
        let handle = PlaylistHandle(local: UUID())

        await #expect(throws: CloudKitLibraryProvider.Failure.self) {
            try await harness.library.renamePlaylist(handle, to: "Nowhere")
        }
    }
}

// MARK: - More than one provider

@Suite("Two providers")
@MainActor
struct TwoProviders {
    @Test("A read is a union — a row only the other provider has still appears")
    func readsAreAUnion() async throws {
        let apple = StubProvider(
            favorites: [
                FavoriteRow(
                    id: UUID(),
                    catalogID: Fix.other,
                    displayName: "Something Else",
                    favoritedAt: Fix.t0,
                    origin: .appleLibrary
                )
            ]
        )
        let harness = try Harness(extra: [apple])
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        #expect(await harness.library.favoriteIDs() == [Fix.clean, Fix.other])
    }

    @Test("A capability the provider lacks is sat out, not failed")
    func capabilityGapsAreInvisible() async throws {
        // No artist favoriting — the gap Apple's own catalogue has.
        let apple = StubProvider(capabilities: LibraryCapabilities.all.subtracting(.favoriteArtists))
        let harness = try Harness(extra: [apple])

        try await harness.library.addFavorite(Fix.item(Fix.band))

        #expect(await harness.library.favoriteIDs() == [Fix.band])
        #expect(apple.calls.contains { $0.hasPrefix("addFavorite") } == false)
    }

    @Test("The shelf is identical whichever capabilities came back")
    func theShelfDoesNotNoticeCapabilities() async throws {
        let full = try Harness(extra: [StubProvider(capabilities: .all)])
        let none = try Harness(extra: [StubProvider(capabilities: [])])

        for harness in [full, none] {
            try await harness.library.addFavorite(Fix.item(Fix.band))
            try await harness.library.addFavorite(Fix.item(Fix.clean))
        }

        let a = try await full.library.favorites().items.map(\.id)
        let b = try await none.library.favorites().items.map(\.id)
        #expect(a == b)
    }

    @Test("The other provider failing a write costs the kid nothing")
    func writeFailuresAreDropped() async throws {
        let apple = StubProvider()
        apple.isFailing = true
        let harness = try Harness(extra: [apple])

        try await harness.library.addFavorite(Fix.item(Fix.clean))
        #expect(await harness.library.favoriteIDs() == [Fix.clean])
    }

    @Test("Our own store failing a write is surfaced")
    func ourFailuresAreSurfaced() async throws {
        let harness = try Harness()
        let handle = PlaylistHandle(local: UUID())

        // The one write our store can genuinely refuse: a playlist that is gone.
        await #expect(throws: (any Error).self) {
            try await harness.library.deletePlaylist(handle)
        }
    }

    @Test("A provider that throws on read contributes nothing and is not an error")
    func readFailuresAreQuiet() async throws {
        let apple = StubProvider()
        let harness = try Harness(extra: [apple])
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        apple.isFailing = true

        #expect(try await harness.library.favorites().items.map(\.id) == [Fix.clean])
    }

    @Test("An edit is never attempted on a playlist we did not create")
    func neverEditsAForeignPlaylist() async throws {
        // Declining `.editForeignPlaylists` is how a provider says so, and it is
        // what the Apple Music provider will declare: MusicKit refuses to edit a
        // playlist the app did not create. The merged store enforces the rule
        // through the flag rather than by naming MusicKit, so a provider that
        // genuinely can edit anything is not crippled by a rule about Apple's.
        let apple = StubProvider(
            capabilities: LibraryCapabilities.all.subtracting(.editForeignPlaylists)
        )
        let harness = try Harness(extra: [apple])
        let row = try await harness.library.createPlaylist(named: "Bangers")

        // As if it had been read back from Apple Music rather than made here:
        // an identifier, but no claim that this app created it.
        let record = try #require(harness.kid.playlistRecord(for: row.handle.local))
        record.linkToAppleLibrary(id: "p.foreign", createdByUs: false)
        try harness.context.save()

        apple.calls.removeAll()
        try await harness.library.renamePlaylist(record.handle, to: "Bangers 2")

        #expect(apple.calls.contains { $0.hasPrefix("renamePlaylist") } == false)
        #expect(await harness.library.playlist(record.handle)?.name == "Bangers 2")
    }

    @Test("A playlist with no counterpart is edited in our store alone")
    func aPlaylistWithNoAppleIDIsOursOnly() async throws {
        let apple = StubProvider()
        let harness = try Harness(extra: [apple])
        let row = try await harness.library.createPlaylist(named: "Bangers")

        apple.calls.removeAll()
        try await harness.library.renamePlaylist(row.handle, to: "Bangers 2")

        #expect(apple.calls.contains { $0.hasPrefix("renamePlaylist") } == false)
        #expect(await harness.library.playlist(row.handle)?.name == "Bangers 2")
    }

    @Test("A playlist we did create is edited on both sides")
    func editsOurOwnPlaylistEverywhere() async throws {
        let apple = StubProvider()
        let harness = try Harness(extra: [apple])
        let row = try await harness.library.createPlaylist(named: "Bangers")

        let record = try #require(harness.kid.playlistRecord(for: row.handle.local))
        record.linkToAppleLibrary(id: "p.ours", createdByUs: true)
        try harness.context.save()

        apple.calls.removeAll()
        try await harness.library.renamePlaylist(record.handle, to: "Bangers 2")

        #expect(apple.calls.contains { $0.hasPrefix("renamePlaylist") })
    }
}

// MARK: - The shared-device toggle

@Suite("The shared-device toggle")
@MainActor
struct SharedDevice {
    @Test("On: the other provider is neither read from nor written to")
    func sharedDeviceIsCloudKitOnly() async throws {
        let apple = StubProvider(
            favorites: [
                FavoriteRow(
                    id: UUID(),
                    catalogID: Fix.other,
                    displayName: "Something Else",
                    favoritedAt: Fix.t0,
                    origin: .appleLibrary
                )
            ]
        )
        let harness = try Harness(
            extra: [apple],
            device: .asked(shared: true)
        )

        try await harness.library.addFavorite(Fix.item(Fix.clean))

        #expect(await harness.library.favoriteIDs() == [Fix.clean])
        #expect(apple.calls.isEmpty)
    }

    @Test("Off: both, which is the default")
    func defaultIsBoth() async throws {
        let apple = StubProvider()
        let harness = try Harness(extra: [apple], device: .asked(shared: false))

        try await harness.library.addFavorite(Fix.item(Fix.clean))
        #expect(apple.calls.contains { $0.hasPrefix("addFavorite") })
    }

    @Test("The kid still has a whole library with our store alone")
    func completeWithoutAppleMusic() async throws {
        let harness = try Harness(device: DeviceLibraryState(sharesDeviceWithChild: true))

        try await harness.library.addFavorite(Fix.item(Fix.clean))
        let row = try await harness.library.createPlaylist(
            named: "Bangers",
            songs: [Fix.item(Fix.other)]
        )

        #expect(try await harness.library.favorites().items.count == 1)
        #expect(try await harness.library.songs(in: row.handle).items.count == 1)
        #expect(try await harness.library.searchLibrary("something").items.count == 1)
    }

    @Test("Nothing is read from the other provider before onboarding has asked")
    func noReadBeforeTheQuestion() async throws {
        let apple = StubProvider(
            favorites: [
                FavoriteRow(
                    id: UUID(),
                    catalogID: Fix.other,
                    displayName: "Something Else",
                    favoritedAt: Fix.t0,
                    origin: .appleLibrary
                )
            ]
        )
        let harness = try Harness(extra: [apple], device: .unasked)

        #expect(try await harness.library.favorites().items.isEmpty)
        #expect(apple.calls.contains("favorites") == false)
    }

    @Test("Once asked, the same read adopts what is there")
    func theQuestionOpensTheDoor() async throws {
        let apple = StubProvider(
            favorites: [
                FavoriteRow(
                    id: UUID(),
                    catalogID: Fix.other,
                    displayName: "Something Else",
                    favoritedAt: Fix.t0,
                    origin: .appleLibrary
                )
            ]
        )
        let harness = try Harness(extra: [apple], device: .unasked)
        harness.device.save(.asked(shared: false))

        #expect(try await harness.library.favorites().items.map(\.id) == [Fix.other])
    }

    @Test("An explicit song in the other provider's library never reaches the shelf")
    func theEngineJudgesAdoptedRowsToo() async throws {
        let apple = StubProvider(
            favorites: [
                FavoriteRow(
                    id: UUID(),
                    catalogID: Fix.explicit,
                    displayName: "Swearing",
                    favoritedAt: Fix.t0,
                    origin: .appleLibrary
                )
            ]
        )
        let harness = try Harness(extra: [apple])

        let shelf = try await harness.library.favorites()
        #expect(shelf.items.isEmpty)
        #expect(shelf.blocked.map(\.reason) == [.explicitContent])
    }
}

// MARK: - Deriving the answer

@Suite("Two questions, one answer")
struct DerivingSharedDevice {
    @Test(
        "The library is the kid's own only when the device and the account both are",
        arguments: [
            // shares device, kid has own account, library is a grown-up's
            (false, true, false),  // their own phone, their own account
            (true, true, true),  // the family iPad — the parent's library is signed in
            (false, false, true),  // the hand-me-down: nobody else uses it, still not theirs
            (true, false, true),  // shared, and on a grown-up's account
        ]
    )
    func derivation(shares: Bool, ownAccount: Bool, expected: Bool) {
        let state = DeviceLibraryState(
            sharesDeviceWithChild: shares,
            childHasOwnAccount: ownAccount
        )
        #expect(state.isSharedDevice == expected)
    }

    @Test("The hand-me-down is the case a single question kept getting wrong")
    func handMeDown() {
        // One user, one device, somebody else's library. Asked on its own, "do
        // you share this device?" answers no and means yes.
        let phone = DeviceLibraryState(sharesDeviceWithChild: false, childHasOwnAccount: false)
        #expect(phone.isSharedDevice)
    }

    @Test("Unasked means both providers live, as the spec's default says")
    func unaskedDefault() {
        #expect(DeviceLibraryState.unasked.isSharedDevice == false)
        #expect(DeviceLibraryState.unasked.hasBeenAsked == false)
    }

    @Test("A stored answer this version cannot read reads back as unasked")
    func unreadableIsUnasked() {
        // Which is why changing the shape of the questions costs one re-ask
        // rather than a migration — and re-asking is the safe outcome.
        let suite = "aural-sandbox-tests-device-state"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(Data("not json".utf8), forKey: UserDefaultsDeviceLibraryState.key)

        #expect(UserDefaultsDeviceLibraryState(defaults: defaults).state == .unasked)
    }

    @Test("A saved answer round-trips")
    func roundTrips() {
        let suite = "aural-sandbox-tests-device-state-2"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = UserDefaultsDeviceLibraryState(defaults: defaults)
        let answered = DeviceLibraryState(
            sharesDeviceWithChild: true,
            childHasOwnAccount: false,
            hasBeenAsked: true
        )
        store.save(answered)

        #expect(store.state == answered)
        #expect(store.state.isSharedDevice)
    }
}

// MARK: - Searching the library

@Suite("Searching the kid's own library")
@MainActor
struct LibrarySearch {
    @Test("Matches favorites and playlist entries alike")
    func coversBoth() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try await harness.library.createPlaylist(named: "Bangers", songs: [Fix.item(Fix.other)])

        #expect(try await harness.library.searchLibrary("sunshine").items.map(\.id) == [Fix.clean])
        #expect(try await harness.library.searchLibrary("something").items.map(\.id) == [Fix.other])
    }

    @Test("Case- and diacritic-insensitive, over the title and the subtitle")
    func insensitive() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        // The subtitle is the artist name, which is most of what a kid types.
        #expect(try await harness.library.searchLibrary("cafe").items.count == 1)
        #expect(try await harness.library.searchLibrary("CAFÉ BAND").items.count == 1)
        #expect(try await harness.library.searchLibrary("SUNsh").items.count == 1)
    }

    @Test("Only searches what the kid may still see")
    func searchesTheFilteredSet() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.clean, displayName: "Sunshine") }

        #expect(try await harness.library.searchLibrary("sunshine").items.isEmpty)
    }

    @Test("An empty term matches nothing rather than everything")
    func emptyTerm() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))

        #expect(try await harness.library.searchLibrary("   ").items.isEmpty)
    }

    @Test("A song both favorited and in a playlist appears once")
    func deduplicates() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try await harness.library.createPlaylist(named: "Bangers", songs: [Fix.item(Fix.clean)])

        #expect(try await harness.library.searchLibrary("sunshine").items.count == 1)
    }
}

// MARK: - The stage's exit test

@Suite("Force-quit and relaunch")
@MainActor
struct Durability {
    @Test("A favorite and a playlist are both intact on the next launch")
    func survivesARelaunch() async throws {
        let container = try FamilyStore.inMemoryContainer()

        do {
            let first = try Harness(container: container)
            try await first.library.addFavorite(Fix.item(Fix.record))
            try await first.library.createPlaylist(
                named: "Bangers",
                songs: [Fix.item(Fix.clean), Fix.item(Fix.other)]
            )
        }

        // A second context over the same store: the same thing a relaunch does.
        let second = try Harness(container: container)
        #expect(try await second.library.favorites().items.map(\.id) == [Fix.record])

        let playlist = try #require(await second.library.playlists().first)
        #expect(playlist.name == "Bangers")
        #expect(try await second.library.songs(in: playlist.handle).items.map(\.id) == [
            Fix.clean, Fix.other,
        ])
    }

    @Test("A deny takes both off the kid's screens and leaves the rows alone")
    func aDenyEmptiesTheScreensNotTheStore() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.record))
        let row = try await harness.library.createPlaylist(
            named: "Bangers",
            songs: [Fix.item(Fix.clean)]
        )

        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.band, displayName: "Café Band") }

        #expect(try await harness.library.favorites().items.isEmpty)
        #expect(try await harness.library.songs(in: row.handle).items.isEmpty)

        // Still in the store, both of them.
        #expect(harness.kid.favorites.count == 1)
        #expect(harness.kid.playlists.first?.entries.count == 1)
    }
}
