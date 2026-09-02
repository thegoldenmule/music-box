import CatalogKit
import Foundation
import PolicyEngine

/// The account's library as a test says it is; matches keyed by ISRC or UPC.
actor StubLibrarySource: LibrarySource {
    private let library: [LibraryItem]
    private let catalogMatches: [String: CatalogItem]
    private let playlists: [LibraryPlaylist]
    private let playlistTracks: [String: [LibraryItem]]

    /// Every page asked for, as (kind, limit, offset).
    private(set) var pages: [(ItemKind, Int, Int)] = []
    private(set) var resolveCallCount = 0

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

    func libraryItems(kinds: Set<ItemKind>, limit: Int, offset: Int) async throws -> [LibraryItem] {
        for kind in kinds { pages.append((kind, limit, offset)) }
        return Array(library.filter { kinds.contains($0.kind) }.dropFirst(offset).prefix(limit))
    }

    func searchLibrary(term: String, kinds: Set<ItemKind>, limit: Int) async throws -> [LibraryItem] {
        []
    }

    func resolveToCatalog(_ items: [LibraryItem]) async throws -> LibraryImport {
        resolveCallCount += 1
        var resolved: [CatalogItem] = []
        var discarded: [DiscardedItem] = []
        var matches: [String: CatalogItem] = [:]
        for item in items {
            guard let code = item.isrc ?? item.upc else {
                discarded.append(DiscardedItem(item: item, reason: .noIdentifier))
                continue
            }
            if let match = catalogMatches[code] {
                if !resolved.contains(where: { $0.id == match.id }) { resolved.append(match) }
                matches[item.id] = match
            } else {
                discarded.append(DiscardedItem(item: item, reason: .notInAppleMusic))
            }
        }
        return LibraryImport(resolved: resolved, discarded: discarded, matches: matches)
    }
}

/// Authorization and subscription as a test says they are.
final class StubAccess: CatalogAccess, @unchecked Sendable {
    var hasCloudLibrary = true

    init(hasCloudLibrary: Bool = true) {
        self.hasCloudLibrary = hasCloudLibrary
    }

    func requestAuthorization() async -> AuthorizationStatus { .authorized }

    var authorizationStatus: AuthorizationStatus { .authorized }

    func subscriptionState() async throws -> SubscriptionState {
        SubscriptionState(
            canPlayCatalogContent: true,
            canBecomeSubscriber: false,
            hasCloudLibraryEnabled: hasCloudLibrary
        )
    }

    var subscriptionUpdates: AsyncStream<SubscriptionState> { AsyncStream { $0.finish() } }
}
