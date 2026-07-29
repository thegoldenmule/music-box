import Foundation
import Testing

import PolicyEngine

@testable import CatalogKit

// MARK: - Fixtures

private enum Seed {
    static let band = CatalogID(.artist, "artist-band")
    static let guest = CatalogID(.artist, "artist-guest")
    static let various = CatalogID(.artist, "artist-various")

    static func song(_ n: Int, by artist: CatalogID) -> CatalogItem {
        CatalogItem(
            id: CatalogID(.song, "song-\(n)"),
            title: "Song \(n)",
            rating: .clean,
            ancestors: [Ancestor(id: artist)]
        )
    }

    static func libraryTrack(_ n: Int, isrc: String?) -> LibraryItem {
        LibraryItem(id: "lib-song-\(n)", kind: .song, title: "Song \(n)", isrc: isrc)
    }
}

// MARK: - The artist vote

@Suite("Naming a library artist")
struct ArtistVoteTests {
    @Test("A clear majority wins")
    func majorityWins() {
        let songs = [
            Seed.song(1, by: Seed.band),
            Seed.song(2, by: Seed.band),
            Seed.song(3, by: Seed.band),
            Seed.song(4, by: Seed.guest),
        ]
        #expect(ArtistVote.winner(among: songs) == Seed.band)
    }

    @Test("An exact tie is not a majority")
    func tieLoses() {
        let songs = [
            Seed.song(1, by: Seed.band),
            Seed.song(2, by: Seed.guest),
        ]
        // Strictly more than half, so two-two is nobody. A suggestion grants
        // reach, and a coin flip is not a basis for handing a kid a catalogue.
        #expect(ArtistVote.winner(among: songs) == nil)
    }

    @Test("A plurality that is not a majority loses")
    func pluralityLoses() {
        let songs = [
            Seed.song(1, by: Seed.band),
            Seed.song(2, by: Seed.band),
            Seed.song(3, by: Seed.guest),
            Seed.song(4, by: Seed.various),
        ]
        #expect(ArtistVote.winner(among: songs) == nil)
    }

    @Test("Songs with no artist are not counted at all")
    func noArtistDoesNotVote() {
        let songs = [
            Seed.song(1, by: Seed.band),
            Seed.song(2, by: Seed.band),
            CatalogItem(id: CatalogID(.song, "song-3"), title: "Orphan", rating: .clean),
        ]
        // Two of two voters agree, not two of three — an unresolvable song must
        // not be able to drag a real majority below the line.
        #expect(ArtistVote.winner(among: songs) == Seed.band)
    }

    @Test("An empty artist identifier is dropped rather than counted")
    func emptyIdentifierIsDropped() {
        let empty = CatalogID(.artist, "")
        let songs = [
            Seed.song(1, by: empty),
            Seed.song(2, by: empty),
            Seed.song(3, by: empty),
            Seed.song(4, by: Seed.band),
        ]
        // A relationship can arrive with no identifier in it. Counting those
        // together collapses every affected artist onto one bogus winner, which
        // would then be suggested — and allowed.
        #expect(ArtistVote.winner(among: songs) == Seed.band)
    }

    @Test("Nothing to count is nobody, not a crash")
    func emptyIsNil() {
        #expect(ArtistVote.winner(among: []) == nil)
    }

    @Test("A library artist resolves through their songs")
    func resolvesThroughSongs() async throws {
        let source = StubLibrarySource(
            library: [
                LibraryItem(id: "lib-artist", kind: .artist, title: "Song"),
                Seed.libraryTrack(1, isrc: "A"),
                Seed.libraryTrack(2, isrc: "B"),
            ],
            catalogMatches: [
                "A": Seed.song(1, by: Seed.band),
                "B": Seed.song(2, by: Seed.band),
            ]
        )
        let artist = LibraryItem(id: "lib-artist", kind: .artist, title: "Song")

        guard case .resolved(let item) = try await source.resolveArtist(artist) else {
            Issue.record("expected a resolution")
            return
        }
        #expect(item.id == Seed.band)
    }

    @Test("A disagreeing sample refuses rather than guessing")
    func disagreementIsAmbiguous() async throws {
        let source = StubLibrarySource(
            library: [Seed.libraryTrack(1, isrc: "A"), Seed.libraryTrack(2, isrc: "B")],
            catalogMatches: [
                "A": Seed.song(1, by: Seed.band),
                "B": Seed.song(2, by: Seed.guest),
            ]
        )
        let artist = LibraryItem(id: "lib-artist", kind: .artist, title: "Song")
        #expect(try await source.resolveArtist(artist) == .ambiguous)
    }

    @Test("An artist whose songs match nothing is not in Apple Music")
    func unmatchedIsAbsent() async throws {
        let source = StubLibrarySource(
            library: [Seed.libraryTrack(1, isrc: "A")],
            catalogMatches: [:]
        )
        let artist = LibraryItem(id: "lib-artist", kind: .artist, title: "Song")
        #expect(try await source.resolveArtist(artist) == .notInAppleMusic)
    }
}

// MARK: - Snapshotting a playlist

@Suite("Snapshotting a library playlist")
struct PlaylistSnapshotTests {
    private func source() -> StubLibrarySource {
        StubLibrarySource(
            catalogMatches: [
                "A": Seed.song(1, by: Seed.band),
                "B": Seed.song(2, by: Seed.band),
            ],
            playlists: [
                LibraryPlaylist(id: "pl-1", name: "Road Trip 2019", trackCount: 4, isPersonal: true),
                LibraryPlaylist(
                    id: "pl-2", name: "Today's Hits", curatorName: "Apple Music",
                    trackCount: 0, isPersonal: false
                ),
            ],
            playlistTracks: [
                "pl-1": [
                    Seed.libraryTrack(1, isrc: "A"),
                    Seed.libraryTrack(2, isrc: "B"),
                    // Ripped from a CD: nothing to match on at all.
                    Seed.libraryTrack(3, isrc: nil),
                    // Has a code, but Apple Music has no such release.
                    Seed.libraryTrack(4, isrc: "GONE"),
                ]
            ]
        )
    }

    @Test("A parent's own playlist is offered alongside Apple's, and says which is which")
    func listsBoth() async throws {
        let playlists = try await source().libraryPlaylists(limit: 10)
        #expect(playlists.map(\.name) == ["Road Trip 2019", "Today's Hits"])
        #expect(playlists.map(\.isPersonal) == [true, false])
    }

    @Test("A playlist snapshot resolves the tracks it can and reports the rest")
    func partialSnapshot() async throws {
        let source = source()
        let playlist = try #require(try await source.libraryPlaylists(limit: 10).first)
        let tracks = try await source.tracks(of: playlist)
        let imported = try await source.resolveToCatalog(tracks)

        #expect(imported.resolved.map(\.id) == [Seed.song(1, by: Seed.band).id, Seed.song(2, by: Seed.band).id])
        // Shown to the parent before they commit, with the reason on each —
        // "34 of 39 matched" is the only honest thing to put in front of someone
        // who is about to hand their kid a playlist.
        #expect(imported.discarded.count == 2)
        #expect(imported.discarded.map(\.reason) == [.noIdentifier, .notInAppleMusic])
    }

    @Test("The whole playlist resolves in one batch, however many tracks it has")
    func oneBatch() async throws {
        let source = source()
        let playlist = try #require(try await source.libraryPlaylists(limit: 10).first)
        let tracks = try await source.tracks(of: playlist)
        _ = try await source.resolveToCatalog(tracks)

        #expect(await source.resolveCallCount == 1)
    }

    @Test("A playlist with nothing readable in it snapshots to nothing")
    func emptySnapshot() async throws {
        let source = source()
        let apple = try #require(try await source.libraryPlaylists(limit: 10).last)
        let tracks = try await source.tracks(of: apple)
        #expect(tracks.isEmpty)
    }
}
