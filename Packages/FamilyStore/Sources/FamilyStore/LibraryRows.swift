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

/// Where a kept item came from, copied at write time.
///
/// **The reason this is stored rather than derived.** `Ancestor` — what a
/// `CatalogItem` carries — is `{id, rating}` and has no title in it. A row that
/// stored only ancestry identifiers could not draw an artist named *Adele*
/// without asking the catalog, which would put a network round trip in front of
/// every library open. Copying the names down at insert is the same trade
/// ``FavoriteRow/displayName`` already makes, and buys the same two things: the
/// fold needs no request, and a delisted item still reads as a name.
///
/// It does **not** on its own make the columns draw offline. A row the catalog
/// did not answer for carries no rating, and `UnratedBehavior.block` — the
/// default — turns that down before the fold is reached. What is stored here
/// survives that rule rather than overriding it.
///
/// Five fields and not six: an album's artwork **is** the song's artwork in
/// Apple Music, so ``FavoriteRow/artworkURL`` serves the album row. An artist's
/// is a different image and needs its own.
///
/// Every field is optional and an empty value is a supported state. A heart must
/// not fail because the network did, so a write with nothing resolved still
/// happens and the top-up fills it in on a later read.
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

    /// Nothing was resolved. What the top-up looks for.
    ///
    /// Judged on the identifiers alone: a name without an identifier cannot be
    /// navigated to and is not worth keeping a row out of the top-up for.
    public var isEmpty: Bool { albumID == nil && artistID == nil }

    /// The album as an identifier, when there is one to build.
    public var album: CatalogID? { albumID.map { CatalogID(.album, $0) } }

    /// The artist as an identifier, when there is one to build.
    public var artist: CatalogID? { artistID.map { CatalogID(.artist, $0) } }
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

    /// Empty for an artist, which has none — and for anything written before the
    /// catalog could be asked, until the top-up reaches it.
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

    /// See ``FavoriteRow/ancestry``. A playlist entry is always a song, so this
    /// being empty always means it has not been resolved yet.
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
