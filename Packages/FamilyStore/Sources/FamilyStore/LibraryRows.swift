import Foundation
import PolicyEngine

/// How something got into a kid's library.
///
/// The distinction is what lets a report say which of a kid's favorites they
/// chose and which arrived with the account. A shelf that filled itself on the
/// first read of a parent's Apple Music library is visible as such rather than
/// looking like a very busy week.
public enum LibraryOrigin: String, Sendable, Codable, Hashable, CaseIterable {
    /// Tapped in this app.
    case kid

    /// Found in the Apple Music library and adopted.
    case appleLibrary
}

/// Names one playlist across providers.
///
/// A playlist has no catalog identifier — it does not exist until someone makes
/// it — so it needs a handle. `local` is ours and survives everything;
/// `appleLibraryID` is `nil` when there is no Apple counterpart, either because
/// one was never created or because the provider was not live at the time.
public struct PlaylistHandle: Hashable, Sendable {
    public let local: UUID
    public let appleLibraryID: String?

    public init(local: UUID, appleLibraryID: String? = nil) {
        self.local = local
        self.appleLibraryID = appleLibraryID
    }
}

/// One favorited song, album or artist, as a value.
///
/// Rows rather than records cross the storage boundary for the same reason
/// catalog metadata arrives here as values: a provider seam above this layer has
/// to be implementable by something that is not SwiftData.
///
/// `displayName` and `artworkURL` are the copies made at write time, never
/// refreshed. They are what makes a shelf render before — or without — any
/// network call.
public struct FavoriteRow: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let catalogID: CatalogID
    public let displayName: String
    public let artworkURL: URL?
    public let favoritedAt: Date
    public let origin: LibraryOrigin

    public init(
        id: UUID,
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        favoritedAt: Date,
        origin: LibraryOrigin
    ) {
        self.id = id
        self.catalogID = catalogID
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.favoritedAt = favoritedAt
        self.origin = origin
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

    public init(
        id: UUID,
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        position: Int,
        addedAt: Date
    ) {
        self.id = id
        self.catalogID = catalogID
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.position = position
        self.addedAt = addedAt
    }
}

/// One playlist a kid owns, with its songs in order.
///
/// **Entries are always songs.** Albums and artists can be favorited but never
/// added to a playlist: what would play is ambiguous, and the player queues
/// songs.
public struct PlaylistRow: Sendable, Hashable, Identifiable {
    public let handle: PlaylistHandle
    public let name: String
    public let createdAt: Date
    public let modifiedAt: Date

    /// True only when this app created the Apple counterpart. Never inferred —
    /// see ``PlaylistRecord/appleIsOurs``.
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
