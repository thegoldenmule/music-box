import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

/// Which store something lives in.
///
/// Callers never name one of these. It exists so ``MergedLibrary`` can decide
/// which providers are live and which write is awaited — nothing above the seam
/// asks where a favorite came from.
public enum LibraryProviderID: String, Sendable, Hashable, CaseIterable {
    /// Ours. **Always live**, which is what makes the feature complete with
    /// Apple Music absent.
    case cloudKit

    /// The account's real Apple Music library. Live when `isSharedDevice` is
    /// false, which is the default.
    case appleMusic
}

/// What a provider can actually do.
///
/// **Absence is not failure** — it is a provider sitting one operation out while
/// the others carry it. Two of the gaps are Apple's and permanent: an artist has
/// no "add to library" form, and MusicKit edits only playlists this app created.
///
/// Nothing about any of this is ever shown to a kid. A capability gap is
/// admin-facing, and the shelf reads identically whichever flags came back.
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

    /// Everything. What our own store can do, and the yardstick the Apple
    /// provider will be measured against once it exists.
    public static let all: LibraryCapabilities = [
        .favoriteSongs, .favoriteAlbums, .favoriteArtists,
        .createPlaylists, .editOwnPlaylists, .editForeignPlaylists,
    ]

    /// The flag that governs favoriting one kind of thing.
    ///
    /// One kid-facing verb, a different Apple primitive per kind: a song or
    /// album is *added to the library*, an artist has no library form at all.
    /// Returns `nil` for a playlist, which is not favoritable — it is owned.
    public static func favoriting(_ kind: ItemKind) -> LibraryCapabilities? {
        switch kind {
        case .song: .favoriteSongs
        case .album: .favoriteAlbums
        case .artist: .favoriteArtists
        case .playlist: nil
        }
    }
}

/// The kid's library, whatever is actually holding it.
///
/// Callers never ask which provider something lives in; they ask
/// ``MergedLibrary``. This protocol exists so that the CloudKit store and the
/// Apple Music library are the same shape to everything above them — and so the
/// whole feature can be tested against stubs with no network and no device.
///
/// Every method may be declined rather than performed: see
/// ``LibraryCapabilities``. A provider that lacks a capability is never asked.
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

    /// Records lineage for rows that were written without it.
    ///
    /// Separate from every other write because it is not something the kid did:
    /// it is a row catching up. Defaulted to a no-op, because a provider may have
    /// nowhere to put this — MusicKit's library has no field for it — and a
    /// provider that cannot store lineage is not a broken provider, it is one
    /// whose rows get folded from whatever ``MergedLibrary`` resolves on the pass.
    func recordAncestry(_ ancestry: [CatalogID: LibraryAncestry]) async throws

    func playlists() async throws -> [PlaylistRow]
    func createPlaylist(named name: String, songs: [LibrarySong]) async throws -> PlaylistRow
    func addToPlaylist(_ handle: PlaylistHandle, song: LibrarySong) async throws
    func removeFromPlaylist(_ handle: PlaylistHandle, song: CatalogID) async throws

    /// Reorders a playlist to exactly this sequence.
    ///
    /// Not in the spec's method list, which names create, add, remove, rename
    /// and delete — but the stage that ships those ships drag-to-reorder too,
    /// and expressing a drag as a remove and an add would lose `addedAt` and
    /// make one gesture two writes.
    func reorderPlaylist(_ handle: PlaylistHandle, to order: [CatalogID]) async throws
    func renamePlaylist(_ handle: PlaylistHandle, to name: String) async throws
    func deletePlaylist(_ handle: PlaylistHandle) async throws
}

extension LibraryProvider {
    public func recordAncestry(_ ancestry: [CatalogID: LibraryAncestry]) async throws {}

    /// Whether this provider can favorite this kind of thing at all.
    public func canFavorite(_ kind: ItemKind) -> Bool {
        guard let flag = LibraryCapabilities.favoriting(kind) else { return false }
        return capabilities.contains(flag)
    }
}
