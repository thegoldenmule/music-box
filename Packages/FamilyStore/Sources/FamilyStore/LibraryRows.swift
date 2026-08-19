import Foundation
import PolicyEngine

/// How something got into a kid's library — lets a report tell chosen from adopted
public enum LibraryOrigin: String, Sendable, Codable, Hashable, CaseIterable {
    /// Tapped in this app.
    case kid

    /// Found in the Apple Music library and adopted.
    case appleLibrary
}

/// A handle, since a playlist has no catalog id; `local` is ours and survives.
public struct PlaylistHandle: Hashable, Sendable {
    public let local: UUID
    public let appleLibraryID: String?

    public init(local: UUID, appleLibraryID: String? = nil) {
        self.local = local
        self.appleLibraryID = appleLibraryID
    }
}

/// Stored, not derived — `CatalogItem` carries no title, and deriving one
/// would put a network call in front of every library open. Doesn't itself
/// bypass `UnratedBehavior.block`. Five fields: an artist's artwork is the
/// only one not already covered by ``FavoriteRow/artworkURL``. All optional —
/// a heart must not fail because the network did; the top-up fills gaps later.
public struct LibraryAncestry: Sendable, Hashable, Codable {
    public var albumID: String?
    public var albumName: String?
    public var artistID: String?
    public var artistName: String?
    public var artistArtworkURL: URL?

    public init(
        albumID: String? = nil,
        albumName: String? = nil,
        artistID: String? = nil,
        artistName: String? = nil,
        artistArtworkURL: URL? = nil
    ) {
        self.albumID = albumID
        self.albumName = albumName
        self.artistID = artistID
        self.artistName = artistName
        self.artistArtworkURL = artistArtworkURL
    }

    public static let none = LibraryAncestry()

    /// Judged on identifiers alone — a name with none isn't worth a top-up.
    public var isEmpty: Bool { albumID == nil && artistID == nil }

    /// The album as an identifier, when there is one to build.
    public var album: CatalogID? { albumID.map { CatalogID(.album, $0) } }

    /// The artist as an identifier, when there is one to build.
    public var artist: CatalogID? { artistID.map { CatalogID(.artist, $0) } }
}

/// A value, not a record, so the provider seam above needn't be SwiftData.
public struct FavoriteRow: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let catalogID: CatalogID
    public let displayName: String
    public let artworkURL: URL?
    public let favoritedAt: Date
    public let origin: LibraryOrigin

    /// Empty for an artist, or until the top-up resolves it.
    public let ancestry: LibraryAncestry

    public init(
        id: UUID,
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        favoritedAt: Date,
        origin: LibraryOrigin,
        ancestry: LibraryAncestry = .none
    ) {
        self.id = id
        self.catalogID = catalogID
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.favoritedAt = favoritedAt
        self.origin = origin
        self.ancestry = ancestry
    }
}

/// One song in a playlist. Always a song — see ``PlaylistRow``.
public struct PlaylistEntryRow: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let catalogID: CatalogID
    public let displayName: String
    public let artworkURL: URL?

    /// 0-based and contiguous. Gaps are not a supported state.
    public let position: Int
    public let addedAt: Date

    /// Always a song, so empty always means unresolved, not inapplicable.
    public let ancestry: LibraryAncestry

    public init(
        id: UUID,
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        position: Int,
        addedAt: Date,
        ancestry: LibraryAncestry = .none
    ) {
        self.id = id
        self.catalogID = catalogID
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.position = position
        self.addedAt = addedAt
        self.ancestry = ancestry
    }
}

/// Entries are always songs — an album or artist is ambiguous to queue.
public struct PlaylistRow: Sendable, Hashable, Identifiable {
    public let handle: PlaylistHandle
    public let name: String
    public let createdAt: Date
    public let modifiedAt: Date

    /// True only when this app created the Apple counterpart; never inferred.
    public let appleIsOurs: Bool

    public let origin: LibraryOrigin

    /// Sorted by ``PlaylistEntryRow/position``. The order is the content.
    public let entries: [PlaylistEntryRow]

    public var id: UUID { handle.local }

    public init(
        handle: PlaylistHandle,
        name: String,
        createdAt: Date,
        modifiedAt: Date,
        appleIsOurs: Bool,
        origin: LibraryOrigin,
        entries: [PlaylistEntryRow]
    ) {
        self.handle = handle
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.appleIsOurs = appleIsOurs
        self.origin = origin
        self.entries = entries
    }
}
