import Foundation

import CatalogKit
import PolicyEngine

/// Returns what tests hand it, records requests — why CatalogSource is a protocol.
actor StubCatalogSource: CatalogSource {
    struct SearchCall: Equatable, Sendable {
        let term: String
        let kinds: Set<ItemKind>
        let limit: Int
        let offset: Int
    }

    private var pages: [CatalogPage]
    private var pagesByKind: [ItemKind: [CatalogPage]]
    private var ancestry: [CatalogID: [Ancestor]]
    private var children: [CatalogID: [CatalogItem]]
    private var items: [CatalogID: CatalogItem]
    private var artists: [CatalogID: [CatalogItem]]
    private var topSongs: [CatalogID: [CatalogItem]]
    private var similarArtists: [CatalogID: [CatalogItem]]
    private var relatedAlbums: [CatalogID: [CatalogItem]]

    private(set) var searchCalls: [SearchCall] = []
    private(set) var ancestryCallCount = 0
    private(set) var ancestryResolvedCount = 0
    private(set) var itemCallCount = 0

    /// - Parameter pagesByKind: separate queues; a shared `pages` races per kind.
    init(
        pages: [CatalogPage] = [],
        pagesByKind: [ItemKind: [CatalogPage]] = [:],
        ancestry: [CatalogID: [Ancestor]] = [:],
        children: [CatalogID: [CatalogItem]] = [:],
        items: [CatalogID: CatalogItem] = [:],
        artists: [CatalogID: [CatalogItem]] = [:],
        topSongs: [CatalogID: [CatalogItem]] = [:],
        similarArtists: [CatalogID: [CatalogItem]] = [:],
        relatedAlbums: [CatalogID: [CatalogItem]] = [:]
    ) {
        self.pages = pages
        self.pagesByKind = pagesByKind
        self.ancestry = ancestry
        self.children = children
        self.items = items
        self.artists = artists
        self.topSongs = topSongs
        self.similarArtists = similarArtists
        self.relatedAlbums = relatedAlbums
    }

    func search(
        term: String,
        kinds: Set<ItemKind>,
        limit: Int,
        offset: Int
    ) async throws -> CatalogPage {
        searchCalls.append(SearchCall(term: term, kinds: kinds, limit: limit, offset: offset))

        if kinds.count == 1, let kind = kinds.first, var queue = pagesByKind[kind] {
            guard !queue.isEmpty else { return .empty }
            let page = queue.removeFirst()
            pagesByKind[kind] = queue
            return page
        }

        guard !pages.isEmpty else { return .empty }
        return pages.removeFirst()
    }

    /// Counts by kind — searchCalls' completion order makes hand-counting a race.
    func searchCallCount(for kind: ItemKind) -> Int {
        searchCalls.filter { $0.kinds == [kind] }.count
    }

    func item(for id: CatalogID) async throws -> CatalogItem? {
        itemCallCount += 1
        return items[id]
    }

    func children(of id: CatalogID) async throws -> [CatalogItem] {
        children[id] ?? []
    }

    func artists(of id: CatalogID) async throws -> [CatalogItem] {
        artists[id] ?? []
    }

    func topSongs(of id: CatalogID) async throws -> [CatalogItem] {
        topSongs[id] ?? []
    }

    func similarArtists(of id: CatalogID) async throws -> [CatalogItem] {
        similarArtists[id] ?? []
    }

    func relatedAlbums(of id: CatalogID) async throws -> [CatalogItem] {
        relatedAlbums[id] ?? []
    }

    func resolveAncestry(for items: [CatalogItem]) async throws -> [CatalogItem] {
        ancestryCallCount += 1
        ancestryResolvedCount += items.count
        return items.map { item in
            guard item.ancestors.isEmpty, let found = ancestry[item.id] else { return item }
            return item.withAncestors(found)
        }
    }
}

/// Resolves what the test says; the one rule that matters: no match, discarded.
actor StubLibrarySource: LibrarySource {
    private var library: [LibraryItem]
    private var catalogMatches: [String: CatalogItem]
    private var playlists: [LibraryPlaylist]
    private var playlistTracks: [String: [LibraryItem]]

    private(set) var resolveCallCount = 0

    /// - Parameter catalogMatches: keyed by ISRC/UPC; absent means not on Apple.
    init(
        library: [LibraryItem] = [],
        catalogMatches: [String: CatalogItem] = [:],
        playlists: [LibraryPlaylist] = [],
        playlistTracks: [String: [LibraryItem]] = [:]
    ) {
        self.library = library
        self.catalogMatches = catalogMatches
        self.playlists = playlists
        self.playlistTracks = playlistTracks
    }

    func libraryPlaylists(limit: Int) async throws -> [LibraryPlaylist] {
        Array(playlists.prefix(limit))
    }

    func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryItem] {
        playlistTracks[playlist.id] ?? []
    }

    func libraryArtists(limit: Int) async throws -> [LibraryItem] {
        Array(library.filter { $0.kind == .artist }.prefix(limit))
    }

    /// The real shape without MusicKit: sample songs, let ArtistVote decide.
    func resolveArtist(_ artist: LibraryItem) async throws -> ArtistResolution {
        guard artist.kind == .artist else { return .notInAppleMusic }
        let songs = try await searchLibrary(
            term: artist.title, kinds: [.song], limit: ArtistVote.sample
        )
        let matched = try await resolveToCatalog(songs)
        guard !matched.resolved.isEmpty else { return .notInAppleMusic }
        guard let winner = ArtistVote.winner(among: matched.resolved) else { return .ambiguous }
        return .resolved(CatalogItem(id: winner, title: artist.title))
    }

    func libraryItems(kinds: Set<ItemKind>, limit: Int) async throws -> [LibraryItem] {
        Array(library.filter { kinds.contains($0.kind) }.prefix(limit))
    }

    func searchLibrary(term: String, kinds: Set<ItemKind>, limit: Int) async throws -> [LibraryItem] {
        Array(
            library
                .filter { kinds.contains($0.kind) && $0.title.localizedCaseInsensitiveContains(term) }
                .prefix(limit)
        )
    }

    func resolveToCatalog(_ items: [LibraryItem]) async throws -> LibraryImport {
        resolveCallCount += 1

        var resolved: [CatalogItem] = []
        var discarded: [DiscardedItem] = []

        for item in items {
            switch item.kind {
            case .artist, .playlist:
                discarded.append(DiscardedItem(item: item, reason: .unsupportedKind))
            case .song, .album:
                guard let code = item.isrc ?? item.upc else {
                    discarded.append(DiscardedItem(item: item, reason: .noIdentifier))
                    continue
                }
                if let match = catalogMatches[code] {
                    resolved.append(match)
                } else {
                    discarded.append(DiscardedItem(item: item, reason: .notInAppleMusic))
                }
            }
        }

        return LibraryImport(resolved: resolved, discarded: discarded)
    }
}

// MARK: - Fixtures

enum Fix {
    static let artist = CatalogID(.artist, "artist-A")
    static let album = CatalogID(.album, "album-A")

    static func song(_ n: Int) -> CatalogID { CatalogID(.song, "song-\(n)") }

    static func songItem(
        _ n: Int,
        rating: SandboxContentRating? = .clean,
        ancestors: [Ancestor] = []
    ) -> CatalogItem {
        CatalogItem(
            id: song(n),
            title: "Song \(n)",
            subtitle: "Artist A",
            rating: rating,
            ancestors: ancestors
        )
    }

    static func albumItem(
        _ n: Int,
        rating: SandboxContentRating? = .clean,
        ancestors: [Ancestor] = [],
        isSingle: Bool? = nil,
        trackCount: Int? = nil
    ) -> CatalogItem {
        CatalogItem(
            id: CatalogID(.album, "album-\(n)"),
            title: "Album \(n)",
            subtitle: "Artist A",
            rating: rating,
            ancestors: ancestors,
            isSingle: isSingle,
            trackCount: trackCount
        )
    }

    /// No rating, no lineage — why the engine treats artists as containers.
    static func artistItem(_ n: Int) -> CatalogItem {
        CatalogItem(id: CatalogID(.artist, "artist-\(n)"), title: "Artist \(n)", rating: nil)
    }

    /// A library song. No ISRC means a raw file — nothing to match on.
    static func librarySong(_ n: Int, isrc: String?) -> LibraryItem {
        LibraryItem(
            id: "library-song-\(n)",
            kind: .song,
            title: "Song \(n)",
            subtitle: "Artist A",
            isrc: isrc
        )
    }

    static func libraryAlbum(_ n: Int, upc: String?) -> LibraryItem {
        LibraryItem(
            id: "library-album-\(n)",
            kind: .album,
            title: "Album \(n)",
            subtitle: "Artist A",
            upc: upc
        )
    }

    static func page(_ items: [CatalogItem], hasMore: Bool = true) -> CatalogPage {
        CatalogPage(items: items, hasMore: hasMore)
    }

    /// A page of `count` songs, alternating clean and explicit.
    static func mixedPage(_ count: Int, startingAt start: Int = 0, hasMore: Bool = true) -> CatalogPage {
        page(
            (start..<(start + count)).map { songItem($0, rating: $0.isMultiple(of: 2) ? .clean : .explicit) },
            hasMore: hasMore
        )
    }

    static func engine(
        _ mode: SandboxMode = .denyPlusAuto,
        _ entries: [PolicyEntry] = [],
        unrated: UnratedBehavior = .block
    ) -> PolicyEngine {
        PolicyEngine(policy: Policy(mode: mode, entries: entries, unratedBehavior: unrated))
    }
}
