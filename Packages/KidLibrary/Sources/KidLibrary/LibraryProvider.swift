import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

/// Which store something lives in; only `MergedLibrary` ever asks.
public enum LibraryProviderID: String, Sendable, Hashable, CaseIterable {
    /// Ours, always live — the feature works with Apple Music absent.
    case cloudKit

    /// The real library; live when `isSharedDevice` is false, the default.
    case appleMusic
}

/// What a provider can do; absence isn't failure, just sitting one out.
public struct LibraryCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let favoriteSongs = LibraryCapabilities(rawValue: 1 << 0)
    public static let favoriteAlbums = LibraryCapabilities(rawValue: 1 << 1)
    public static let favoriteArtists = LibraryCapabilities(rawValue: 1 << 2)
    public static let createPlaylists = LibraryCapabilities(rawValue: 1 << 3)
    public static let editOwnPlaylists = LibraryCapabilities(rawValue: 1 << 4)
    public static let editForeignPlaylists = LibraryCapabilities(rawValue: 1 << 5)

    /// Everything our store can do — the bar the Apple provider must meet.
    public static let all: LibraryCapabilities = [
        .favoriteSongs, .favoriteAlbums, .favoriteArtists,
        .createPlaylists, .editOwnPlaylists, .editForeignPlaylists,
    ]

    /// The flag for one favorite kind; nil for a playlist, which is owned.
    public static func favoriting(_ kind: ItemKind) -> LibraryCapabilities? {
        switch kind {
        case .song: .favoriteSongs
        case .album: .favoriteAlbums
        case .artist: .favoriteArtists
        case .playlist: nil
        }
    }
}

/// The kid's library; callers never ask which provider, only `MergedLibrary`.
public protocol LibraryProvider: Sendable {
    var id: LibraryProviderID { get }
    var capabilities: LibraryCapabilities { get }

    func favorites() async throws -> [FavoriteRow]
    func addFavorite(
        _ id: CatalogID,
        displayName: String,
        artworkURL: URL?,
        origin: LibraryOrigin,
        ancestry: LibraryAncestry
    ) async throws
    func removeFavorite(_ id: CatalogID) async throws

    /// Lineage for rows without it; a no-op if a provider has no field for it.
    func recordAncestry(_ ancestry: [CatalogID: LibraryAncestry]) async throws

    // MARK: - The library index
        // Defaulted to nothing — our projection, not something Apple Music holds.

    /// Everything the index holds for this kid.
    func indexed() async throws -> [LibraryIndexRow]

    /// Adds to what one favorite has already brought in.
    func appendIndex(from source: CatalogID, rows: [LibraryIndexRow]) async throws

    /// Whether this favorite has been walked by the current version of the walk.
    func isIndexed(_ source: CatalogID) async -> Bool

    /// Drops everything one favorite brought in.
    func removeIndex(from source: CatalogID) async throws

    func playlists() async throws -> [PlaylistRow]
    func createPlaylist(named name: String, songs: [LibrarySong]) async throws -> PlaylistRow
    func addToPlaylist(_ handle: PlaylistHandle, song: LibrarySong) async throws
    func removeFromPlaylist(_ handle: PlaylistHandle, song: CatalogID) async throws

    /// Reorders to this sequence; a drag as remove-then-add would lose `addedAt`.
    func reorderPlaylist(_ handle: PlaylistHandle, to order: [CatalogID]) async throws
    func renamePlaylist(_ handle: PlaylistHandle, to name: String) async throws
    func deletePlaylist(_ handle: PlaylistHandle) async throws
}

extension LibraryProvider {
    public func recordAncestry(_ ancestry: [CatalogID: LibraryAncestry]) async throws {}

    public func indexed() async throws -> [LibraryIndexRow] { [] }
    public func appendIndex(from source: CatalogID, rows: [LibraryIndexRow]) async throws {}
    public func isIndexed(_ source: CatalogID) async -> Bool { false }
    public func removeIndex(from source: CatalogID) async throws {}

    /// Whether this provider can favorite this kind of thing at all.
    public func canFavorite(_ kind: ItemKind) -> Bool {
        guard let flag = LibraryCapabilities.favoriting(kind) else { return false }
        return capabilities.contains(flag)
    }
}
