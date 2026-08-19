import Foundation
import PolicyEngine
import SwiftData

/// **Not a favorite** — never fills a heart, never chosen; the artist was.
/// **Not a permission** — judged before it draws, player re-checks live.
/// **Rating stored, not resolved live**: this table is unbounded, so a stored
/// rating and ancestry keep the verdict local and network-free.
/// **Exempt from retention like favorites** — survives `deleteHistory`,
/// unlike ``RecentTrailRecord``, which follows events instead.
@Model
public final class LibraryIndexRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// Always an Apple Music catalog identifier.
    public private(set) var catalogID: String = ""

    /// `"album"` or `"song"` — never artist, which a walk starts from, not produces.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    /// Copied at index time and never refreshed, like everywhere else.
    public private(set) var displayName: String = ""
    public private(set) var artworkURL: URL?

    /// Where a song sits on its album, so a record reads in its own order.
    public private(set) var trackNumber: Int?

    /// `StoredRating.stored`. See the note above on why this is here.
    public private(set) var rating: String = StoredRating.unknown.stored

    // Lineage, the same five columns as `FavoriteRecord`.
    public private(set) var albumID: String?
    public private(set) var albumName: String?
    public private(set) var artistID: String?
    public private(set) var artistName: String?
    public private(set) var artistArtworkURL: URL?

    /// Source and kind together — catalog IDs are only unique within a type.
    public private(set) var sourceID: String = ""
    public private(set) var sourceKind: String = ItemKind.artist.rawValue

    /// Which walk produced this row. See ``LibraryIndex/version``.
    public private(set) var version: Int = 0

    public var kid: Kid?

    public init(
        id: UUID = UUID(),
        row: LibraryIndexRow,
        at: Date = .now
    ) {
        self.id = id
        catalogID = row.catalogID.rawValue
        itemKind = row.catalogID.kind.rawValue
        displayName = row.displayName
        artworkURL = row.artworkURL
        trackNumber = row.trackNumber
        rating = row.rating.stored
        albumID = row.ancestry.albumID
        albumName = row.ancestry.albumName
        artistID = row.ancestry.artistID
        artistName = row.ancestry.artistName
        artistArtworkURL = row.ancestry.artistArtworkURL
        sourceID = row.source.rawValue
        sourceKind = row.source.kind.rawValue
        version = row.version
        modifiedAt = at
    }

    /// The typed identifier, or `nil` if the stored strings do not make one.
    public var itemID: CatalogID? {
        guard let kind = ItemKind(rawValue: itemKind) else { return nil }
        return CatalogID(kind, catalogID)
    }

    public var source: CatalogID? {
        guard let kind = ItemKind(rawValue: sourceKind) else { return nil }
        return CatalogID(kind, sourceID)
    }

    public var ancestry: LibraryAncestry {
        LibraryAncestry(
            albumID: albumID,
            albumName: albumName,
            artistID: artistID,
            artistName: artistName,
            artistArtworkURL: artistArtworkURL
        )
    }

    /// `nil` on unreadable, dropped like ``FavoriteRecord/row`` — safety-free.
    public var row: LibraryIndexRow? {
        guard let itemID, let source else { return nil }
        return LibraryIndexRow(
            catalogID: itemID,
            displayName: displayName,
            artworkURL: artworkURL,
            trackNumber: trackNumber,
            rating: StoredRating(stored: rating),
            ancestry: ancestry,
            source: source,
            version: version
        )
    }
}

/// One indexed album or song, as a value.
public struct LibraryIndexRow: Sendable, Hashable {
    public let catalogID: CatalogID
    public let displayName: String
    public let artworkURL: URL?
    public let trackNumber: Int?
    public let rating: StoredRating
    public let ancestry: LibraryAncestry

    /// The favorite that pulled this in.
    public let source: CatalogID

    public let version: Int

    public init(
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        trackNumber: Int? = nil,
        rating: StoredRating = .unknown,
        ancestry: LibraryAncestry = .none,
        source: CatalogID,
        version: Int = LibraryIndex.version
    ) {
        self.catalogID = catalogID
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.trackNumber = trackNumber
        self.rating = rating
        self.ancestry = ancestry
        self.source = source
        self.version = version
    }

    /// Local and complete — stored rating and lineage are all a verdict needs.
    public var policyItem: Item {
        var ancestors: [Ancestor] = []
        if let album = ancestry.album { ancestors.append(Ancestor(id: album)) }
        if let artist = ancestry.artist { ancestors.append(Ancestor(id: artist)) }
        return Item(id: catalogID, rating: rating.rating, ancestors: ancestors)
    }
}

/// Facts about the walk that produced the index.
public enum LibraryIndex {
    /// Distinguishes "genuinely has three albums" from "walked by an old version".
    public static let version = 1
}
