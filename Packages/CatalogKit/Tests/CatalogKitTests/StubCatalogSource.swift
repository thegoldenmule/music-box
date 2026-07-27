import Foundation

import CatalogKit
import PolicyEngine

/// A catalog that returns whatever the test hands it, and records what was
/// asked for.
///
/// The whole reason ``CatalogSource`` is a protocol: the over-fetch loop is the
/// interesting logic in this package, and it can be exercised with no network,
/// no subscription and no device.
actor StubCatalogSource: CatalogSource {
    struct SearchCall: Equatable, Sendable {
        let term: String
        let kinds: Set<ItemKind>
        let limit: Int
        let offset: Int
    }

    private var pages: [CatalogPage]
    private var ancestry: [CatalogID: [Ancestor]]
    private var children: [CatalogID: [CatalogItem]]
    private var items: [CatalogID: CatalogItem]

    private(set) var searchCalls: [SearchCall] = []
    private(set) var ancestryCallCount = 0
    private(set) var ancestryResolvedCount = 0
    private(set) var itemCallCount = 0

    init(
        pages: [CatalogPage] = [],
        ancestry: [CatalogID: [Ancestor]] = [:],
        children: [CatalogID: [CatalogItem]] = [:],
        items: [CatalogID: CatalogItem] = [:]
    ) {
        self.pages = pages
        self.ancestry = ancestry
        self.children = children
        self.items = items
    }

    func search(
        term: String,
        kinds: Set<ItemKind>,
        limit: Int,
        offset: Int
    ) async throws -> CatalogPage {
        searchCalls.append(SearchCall(term: term, kinds: kinds, limit: limit, offset: offset))
        guard !pages.isEmpty else { return .empty }
        return pages.removeFirst()
    }

    func item(for id: CatalogID) async throws -> CatalogItem? {
        itemCallCount += 1
        return items[id]
    }

    func children(of id: CatalogID) async throws -> [CatalogItem] {
        children[id] ?? []
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

/// A library that resolves whatever the test says resolves.
///
/// Models the one rule that matters: an item with no catalog match is discarded,
/// never stored.
actor StubLibrarySource: LibrarySource {
    private var library: [LibraryItem]
    private var catalogMatches: [String: CatalogItem]

    private(set) var resolveCallCount = 0

    /// - Parameter catalogMatches: keyed by ISRC or UPC. Anything absent is
    ///   treated as not being on Apple Music.
    init(library: [LibraryItem] = [], catalogMatches: [String: CatalogItem] = [:]) {
        self.library = library
        self.catalogMatches = catalogMatches
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
