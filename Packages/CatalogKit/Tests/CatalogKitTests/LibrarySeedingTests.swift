import Foundation
import Testing

import CatalogKit
import PolicyEngine

@Suite("Library seeding")
struct LibrarySeedingTests {
    @Test("A library song that exists on Apple Music resolves to its catalog item")
    func resolvesMatchedSong() async throws {
        let sut = StubLibrarySource(
            library: [Fix.librarySong(0, isrc: "US-ABC-00-00001")],
            catalogMatches: ["US-ABC-00-00001": Fix.songItem(0)]
        )

        let result = try await sut.resolveToCatalog(
            try await sut.libraryItems(kinds: [.song], limit: 10)
        )

        #expect(result.resolved.map(\.id) == [Fix.song(0)])
        #expect(result.discarded.isEmpty)
    }

    @Test("A raw file with no recording code is discarded, not stored")
    func discardsFileWithNoIdentifier() async throws {
        let sut = StubLibrarySource(library: [Fix.librarySong(0, isrc: nil)])

        let result = try await sut.resolveToCatalog(
            try await sut.libraryItems(kinds: [.song], limit: 10)
        )

        #expect(result.resolved.isEmpty)
        #expect(result.discarded.map(\.reason) == [.noIdentifier])
    }

    @Test("A coded track Apple Music does not carry is discarded")
    func discardsUnmatchedTrack() async throws {
        let sut = StubLibrarySource(
            library: [Fix.librarySong(0, isrc: "US-ABC-00-99999")],
            catalogMatches: [:]
        )

        let result = try await sut.resolveToCatalog(
            try await sut.libraryItems(kinds: [.song], limit: 10)
        )

        #expect(result.resolved.isEmpty)
        #expect(result.discarded.map(\.reason) == [.notInAppleMusic])
    }

    @Test("Albums resolve on their product code")
    func resolvesAlbumByUPC() async throws {
        let match = CatalogItem(id: Fix.album, title: "Album 0", rating: .clean)
        let sut = StubLibrarySource(
            library: [Fix.libraryAlbum(0, upc: "00602445")],
            catalogMatches: ["00602445": match]
        )

        let result = try await sut.resolveToCatalog(
            try await sut.libraryItems(kinds: [.album], limit: 10)
        )

        #expect(result.resolved.map(\.id) == [Fix.album])
    }

    @Test("A mixed library splits into what resolved and what did not")
    func splitsMixedLibrary() async throws {
        let sut = StubLibrarySource(
            library: [
                Fix.librarySong(0, isrc: "isrc-0"),
                Fix.librarySong(1, isrc: nil),
                Fix.librarySong(2, isrc: "isrc-missing"),
                Fix.libraryAlbum(3, upc: "upc-3"),
            ],
            catalogMatches: [
                "isrc-0": Fix.songItem(0),
                "upc-3": CatalogItem(id: Fix.album, title: "Album 3"),
            ]
        )

        let result = try await sut.resolveToCatalog(
            try await sut.libraryItems(kinds: [.song, .album], limit: 10)
        )

        #expect(result.resolved.count == 2)
        #expect(result.discarded.count == 2)
        #expect(Set(result.discarded.map(\.reason)) == [.noIdentifier, .notInAppleMusic])
    }

    @Test("Discards keep the item, so the parent can be shown what did not make it")
    func discardsAreNamed() async throws {
        let sut = StubLibrarySource(library: [Fix.librarySong(7, isrc: nil)])

        let result = try await sut.resolveToCatalog(
            try await sut.libraryItems(kinds: [.song], limit: 10)
        )

        #expect(result.discarded.first?.item.title == "Song 7")
    }

    @Test("Library artists and playlists cannot be matched at all")
    func discardsUnsupportedKinds() async throws {
        let sut = StubLibrarySource()
        let items = [
            LibraryItem(id: "a", kind: .artist, title: "Some Band"),
            LibraryItem(id: "p", kind: .playlist, title: "Road Trip"),
        ]

        let result = try await sut.resolveToCatalog(items)

        #expect(result.resolved.isEmpty)
        #expect(result.discarded.map(\.reason) == [.unsupportedKind, .unsupportedKind])
    }

    @Test("Every library row is matched by its own id, in the caller's order")
    func matchesKeepTheCallersHandle() async throws {
        let added = Date(timeIntervalSince1970: 1_000)
        let sut = StubLibrarySource(
            library: [
                LibraryItem(
                    id: "library-song-1", kind: .song, title: "Song 1", isrc: "isrc-1",
                    addedAt: added
                ),
                Fix.librarySong(0, isrc: "isrc-0"),
            ],
            catalogMatches: ["isrc-0": Fix.songItem(0), "isrc-1": Fix.songItem(1)]
        )

        let library = try await sut.libraryItems(kinds: [.song], limit: 10)
        let result = try await sut.resolveToCatalog(library)

        // Walking the library side keeps its order and its dates; `resolved`
        // alone could not say which row was added when.
        let walked = library.filter { result.matches[$0.id] != nil }
        #expect(walked.compactMap { result.matches[$0.id]?.id } == [Fix.song(1), Fix.song(0)])
        #expect(walked.map(\.addedAt) == [added, nil])
    }

    @Test("Two library rows with one recording code both find their match")
    func duplicateCodesBothMatch() async throws {
        let sut = StubLibrarySource(
            library: [Fix.librarySong(0, isrc: "shared"), Fix.librarySong(1, isrc: "shared")],
            catalogMatches: ["shared": Fix.songItem(0)]
        )

        let result = try await sut.resolveToCatalog(
            try await sut.libraryItems(kinds: [.song], limit: 10)
        )

        #expect(result.resolved.map(\.id) == [Fix.song(0)])
        #expect(result.matches["library-song-0"]?.id == Fix.song(0))
        #expect(result.matches["library-song-1"]?.id == Fix.song(0))
        #expect(result.discarded.isEmpty)
    }

    @Test("A library reads in pages, by offset")
    func pagesByOffset() async throws {
        let sut = StubLibrarySource(
            library: (0..<5).map { Fix.librarySong($0, isrc: "isrc-\($0)") }
        )

        let first = try await sut.libraryItems(kinds: [.song], limit: 2, offset: 0)
        let third = try await sut.libraryItems(kinds: [.song], limit: 2, offset: 4)

        #expect(first.map(\.title) == ["Song 0", "Song 1"])
        #expect(third.map(\.title) == ["Song 4"])
    }

    @Test("Searching the library narrows by title")
    func searchesLibrary() async throws {
        let sut = StubLibrarySource(
            library: [Fix.librarySong(1, isrc: "a"), Fix.librarySong(2, isrc: "b")]
        )

        let found = try await sut.searchLibrary(term: "Song 2", kinds: [.song], limit: 10)

        #expect(found.map(\.title) == ["Song 2"])
    }
}

@Suite("Seeded entries obey the same rules as anything else")
struct SeededEntryTests {
    /// Resolving attaches catalog ancestry, so a deny on the artist reaches it.
    @Test("A deny on the artist reaches a song seeded from the library")
    func denyReachesSeededSong() async throws {
        let seeded = Fix.songItem(0, rating: .clean, ancestors: [Ancestor(id: Fix.artist)])
        let library = StubLibrarySource(
            library: [Fix.librarySong(0, isrc: "isrc-0")],
            catalogMatches: ["isrc-0": seeded]
        )

        let imported = try await library.resolveToCatalog(
            try await library.libraryItems(kinds: [.song], limit: 10)
        )
        let engine = Fix.engine(.denyPlusAuto, [.deny(Fix.artist)])
        let resolved = try #require(imported.resolved.first)

        #expect(engine.evaluate(resolved.policyItem) == .blocked(.deniedByParent(Fix.artist)))
    }

    @Test("An explicit track seeded from the library is still screened out")
    func explicitSeedIsStillFiltered() async throws {
        let seeded = Fix.songItem(0, rating: .explicit)
        let library = StubLibrarySource(
            library: [Fix.librarySong(0, isrc: "isrc-0")],
            catalogMatches: ["isrc-0": seeded]
        )

        let imported = try await library.resolveToCatalog(
            try await library.libraryItems(kinds: [.song], limit: 10)
        )
        let resolved = try #require(imported.resolved.first)

        #expect(Fix.engine().evaluate(resolved.policyItem) == .blocked(.explicitContent))
    }

    @Test("A seeded entry is an ordinary catalog ID — nothing marks it as library-sourced")
    func seededEntriesAreOrdinaryCatalogIDs() async throws {
        let library = StubLibrarySource(
            library: [Fix.librarySong(0, isrc: "isrc-0")],
            catalogMatches: ["isrc-0": Fix.songItem(0)]
        )

        let imported = try await library.resolveToCatalog(
            try await library.libraryItems(kinds: [.song], limit: 10)
        )
        let entry = PolicyEntry.allow(try #require(imported.resolved.first).id)

        #expect(entry.id == Fix.song(0))
        #expect(entry.id.kind == .song)
    }
}
