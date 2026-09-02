import Foundation
import Testing

import CatalogKit
import FamilyStore
import PolicyEngine

@testable import KidLibrary

@Suite("The Apple Music library, read")
@MainActor
struct AppleMusicLibraryProviderTests {
    /// A clock the test advances; the provider's staleness reads from it.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    static let added = Date(timeIntervalSince1970: 500_000)

    static func song(_ n: Int, isrc: String? = nil, addedAt: Date? = added) -> LibraryItem {
        LibraryItem(
            id: "lib-song-\(n)",
            kind: .song,
            title: "Song \(n)",
            subtitle: "Artist A",
            isrc: isrc,
            albumTitle: "Album A",
            addedAt: addedAt
        )
    }

    static func album(_ n: Int, upc: String? = nil) -> LibraryItem {
        LibraryItem(id: "lib-album-\(n)", kind: .album, title: "Album \(n)", upc: upc)
    }

    static let artistA = CatalogID(.artist, "artist-a")
    static let albumA = CatalogID(.album, "album-a")

    static func match(_ n: Int) -> CatalogItem {
        CatalogItem(
            id: CatalogID(.song, "song-\(n)"),
            title: "Song \(n)",
            rating: .clean,
            ancestors: [Ancestor(id: albumA, rating: .clean), Ancestor(id: artistA)]
        )
    }

    @MainActor
    struct Wired {
        let source: StubLibrarySource
        let access: StubAccess
        let cache = InMemoryItemCache()
        let clock = Clock()
        let provider: AppleMusicLibraryProvider

        init(
            library: [LibraryItem],
            matches: [String: CatalogItem],
            playlists: [LibraryPlaylist] = [],
            playlistTracks: [String: [LibraryItem]] = [:],
            cloudLibrary: Bool = true,
            limits: AppleLibraryLimits = AppleLibraryLimits()
        ) {
            source = StubLibrarySource(
                library: library,
                catalogMatches: matches,
                playlists: playlists,
                playlistTracks: playlistTracks
            )
            access = StubAccess(hasCloudLibrary: cloudLibrary)
            let clock = self.clock
            provider = AppleMusicLibraryProvider(
                source: source,
                access: access,
                cache: cache,
                limits: limits,
                now: { clock.now }
            )
        }
    }

    @Test("Songs and albums come back as catalog rows; the unmatched are counted")
    func resolvesWhatItCan() async throws {
        let wired = Wired(
            library: [
                Self.song(1, isrc: "isrc-1"),
                Self.song(2, isrc: nil),
                Self.song(3, isrc: "isrc-missing"),
                Self.album(4, upc: "upc-4"),
            ],
            matches: [
                "isrc-1": Self.match(1),
                "upc-4": CatalogItem(id: Self.albumA, title: "Album A", rating: .clean),
            ]
        )

        try await wired.provider.refresh()
        let rows = try await wired.provider.favorites()

        #expect(Set(rows.map(\.catalogID)) == [Self.match(1).id, Self.albumA])
        #expect(rows.allSatisfy { $0.origin == .appleLibrary })
        #expect(wired.provider.lastRead?.unresolved == 2)
        #expect(wired.provider.lastRead?.songs == 1)
        #expect(wired.provider.lastRead?.albums == 1)
    }

    @Test("A row is dated by when the account added it, and named by the catalog")
    func datesAndNames() async throws {
        let wired = Wired(
            library: [Self.song(1, isrc: "isrc-1", addedAt: Self.added), Self.song(2, isrc: "isrc-2", addedAt: nil)],
            matches: ["isrc-1": Self.match(1), "isrc-2": Self.match(2)]
        )

        try await wired.provider.refresh()
        let rows = try await wired.provider.favorites()

        #expect(rows.map(\.favoritedAt) == [Self.added, .distantPast])
        #expect(rows.first?.displayName == "Song 1")
    }

    @Test("Lineage is named from the library side, so the merge never has to")
    func ancestryArrivesNamed() async throws {
        let wired = Wired(library: [Self.song(1, isrc: "isrc-1")], matches: ["isrc-1": Self.match(1)])

        try await wired.provider.refresh()
        let row = try #require(try await wired.provider.favorites().first)

        #expect(row.ancestry.artist == Self.artistA)
        #expect(row.ancestry.artistName == "Artist A")
        #expect(row.ancestry.album == Self.albumA)
        #expect(row.ancestry.albumName == "Album A")
    }

    @Test("The same library row is the same row on every read")
    func rowsAreStable() async throws {
        let wired = Wired(library: [Self.song(1, isrc: "isrc-1")], matches: ["isrc-1": Self.match(1)])

        try await wired.provider.refresh()
        let first = try await wired.provider.favorites().map(\.id)
        wired.clock.now += 3600
        try await wired.provider.refresh()
        let second = try await wired.provider.favorites().map(\.id)

        #expect(first == second)
        #expect(AppleMusicLibraryProvider.stableID(for: "a") != AppleMusicLibraryProvider.stableID(for: "b"))
    }

    @Test("Before any read there is nothing to serve, and nothing to wait for")
    func emptyBeforeTheFirstRead() async throws {
        let wired = Wired(library: [Self.song(1, isrc: "isrc-1")], matches: ["isrc-1": Self.match(1)])

        #expect(try await wired.provider.favorites().isEmpty)
        // That call started the read; joining it is how the app learns it's done.
        try await wired.provider.refresh()
        #expect(try await wired.provider.favorites().count == 1)
    }

    @Test("A fresh snapshot is served without asking the library again")
    func freshIsServedFromMemory() async throws {
        let wired = Wired(library: [Self.song(1, isrc: "isrc-1")], matches: ["isrc-1": Self.match(1)])
        try await wired.provider.refresh()
        let pagesAfterOne = await wired.source.pages.count

        _ = try await wired.provider.favorites()
        _ = try await wired.provider.favorites()
        _ = try await wired.provider.playlists()

        #expect(await wired.source.pages.count == pagesAfterOne)
    }

    @Test("A stale snapshot starts one read behind it, not one per caller")
    func staleStartsOneRead() async throws {
        let wired = Wired(library: [Self.song(1, isrc: "isrc-1")], matches: ["isrc-1": Self.match(1)])
        try await wired.provider.refresh()
        let resolvesAfterOne = await wired.source.resolveCallCount

        wired.clock.now += AppleLibraryLimits().freshFor + 1
        _ = try await wired.provider.favorites()
        _ = try await wired.provider.favorites()
        _ = try await wired.provider.favorites()
        try await wired.provider.refresh()

        #expect(await wired.source.resolveCallCount == resolvesAfterOne + 1)
    }

    @Test("iCloud Music Library off is a reason, and it's the one the read throws")
    func cloudLibraryOffIsSaidOutLoud() async throws {
        let wired = Wired(
            library: [Self.song(1, isrc: "isrc-1")],
            matches: ["isrc-1": Self.match(1)],
            cloudLibrary: false
        )

        await #expect(throws: AppleLibraryUnavailable.cloudLibraryOff) {
            try await wired.provider.refresh()
        }
        #expect(wired.provider.lastFailure is AppleLibraryUnavailable)
        await #expect(throws: AppleLibraryUnavailable.cloudLibraryOff) {
            try await wired.provider.favorites()
        }
        #expect(await wired.source.pages.isEmpty)
    }

    @Test("A read that fails after a good one keeps serving what it had")
    func aLaterFailureKeepsTheSnapshot() async throws {
        let wired = Wired(library: [Self.song(1, isrc: "isrc-1")], matches: ["isrc-1": Self.match(1)])
        try await wired.provider.refresh()

        wired.access.hasCloudLibrary = false
        wired.clock.now += 3600
        await #expect(throws: AppleLibraryUnavailable.cloudLibraryOff) {
            try await wired.provider.refresh()
        }

        #expect(try await wired.provider.favorites().count == 1)
        #expect(wired.provider.lastFailure != nil)
    }

    @Test("Matched items are put where the shelf's lookup will find them")
    func matchesWarmTheCache() async throws {
        let wired = Wired(library: [Self.song(1, isrc: "isrc-1")], matches: ["isrc-1": Self.match(1)])

        try await wired.provider.refresh()

        #expect(await wired.cache.item(for: Self.match(1).id)?.title == "Song 1")
    }

    @Test("Pages run to the cap and stop at a short page")
    func pagesToTheCap() async throws {
        var limits = AppleLibraryLimits()
        limits.songPage = 2
        limits.songs = 3
        let wired = Wired(
            library: (1...5).map { Self.song($0, isrc: "isrc-\($0)") },
            matches: Dictionary(uniqueKeysWithValues: (1...5).map { ("isrc-\($0)", Self.match($0)) }),
            limits: limits
        )

        try await wired.provider.refresh()

        #expect(try await wired.provider.favorites().count == 3)
        let songPages = await wired.source.pages.filter { $0.0 == .song }.map { ($0.1, $0.2) }
        #expect(songPages.map(\.0) == [2, 1])
        #expect(songPages.map(\.1) == [0, 2])
    }

    @Test("The account's own playlists come back in order, under the same handle every read")
    func playlistsAreSnapshotted() async throws {
        let mine = LibraryPlaylist(id: "pl-mine", name: "Road Trip", isPersonal: true)
        let apples = LibraryPlaylist(id: "pl-mix", name: "Favorites Mix", isPersonal: false)
        let wired = Wired(
            library: [],
            matches: ["isrc-1": Self.match(1), "isrc-2": Self.match(2)],
            playlists: [apples, mine],
            playlistTracks: [
                "pl-mine": [
                    Self.song(2, isrc: "isrc-2"),
                    Self.song(3, isrc: "isrc-missing"),
                    Self.song(1, isrc: "isrc-1"),
                    Self.song(2, isrc: "isrc-2"),
                ],
                "pl-mix": [Self.song(1, isrc: "isrc-1")],
            ]
        )

        try await wired.provider.refresh()
        let rows = try await wired.provider.playlists()
        let row = try #require(rows.first)

        #expect(rows.count == 1)
        #expect(row.name == "Road Trip")
        #expect(row.origin == .appleLibrary)
        #expect(row.appleIsOurs == false)
        #expect(row.handle.appleLibraryID == "pl-mine")
        // Order kept, the unmatched dropped, positions contiguous, a repeat twice.
        #expect(row.entries.map(\.catalogID) == [Self.match(2).id, Self.match(1).id, Self.match(2).id])
        #expect(row.entries.map(\.position) == [0, 1, 2])
        #expect(Set(row.entries.map(\.id)).count == 3)
        #expect(wired.provider.lastRead?.playlists == 1)
        #expect(wired.provider.lastRead?.unresolved == 1)

        wired.clock.now += 3600
        try await wired.provider.refresh()
        #expect(try await wired.provider.playlists().first?.handle == row.handle)
    }

    @Test("What the merge names after the fact sticks to the rows")
    func recordedAncestrySticks() async throws {
        let bare = CatalogItem(id: CatalogID(.song, "song-9"), title: "Song 9", rating: .clean)
        let wired = Wired(library: [Self.song(9, isrc: "isrc-9")], matches: ["isrc-9": bare])
        try await wired.provider.refresh()
        #expect(try await wired.provider.favorites().first?.ancestry.isEmpty == true)

        var named = LibraryAncestry()
        named.artistID = Self.artistA.rawValue
        named.artistName = "Artist A"
        try await wired.provider.recordAncestry([bare.id: named])

        #expect(try await wired.provider.favorites().first?.ancestry.artistName == "Artist A")
    }
}
