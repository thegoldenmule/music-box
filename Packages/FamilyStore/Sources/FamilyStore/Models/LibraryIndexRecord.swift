import Foundation
import PolicyEngine
import SwiftData

/// Something the kid's library contains because of something else they kept.
///
/// **The second projection in this store**, and the first one whose source is a
/// favorite rather than an event. Hearting an artist means keeping their work,
/// not keeping a name: the albums and every track on them are what the kid
/// actually wants to browse, and none of that exists anywhere until it is
/// written down here. Hearting an album means the same one level in.
///
/// **Not a favorite, and the distinction is the whole design.** A row here never
/// fills a heart, never appears in ``Kid/favorites``, and is never something the
/// kid chose — they chose the artist. Writing four hundred `FavoriteRecord`s
/// instead would light up four hundred hearts nobody tapped and leave unhearting
/// the artist with no defined meaning.
///
/// **Not a permission either.** Same rule as everything else in the library:
/// being indexed grants nothing. Every row is judged before it is drawn, and the
/// player asks again before any of it makes a sound.
///
/// ### Why the rating is stored here and not on a favorite
///
/// A favorite is one row and resolving it costs part of one batch. This table is
/// unbounded — one hearted artist can bring in a thousand songs — and resolving
/// all of it on every library open would put a thousand-item request in front of
/// a screen that is supposed to filter as a child types. Storing what the
/// catalog said at index time makes the verdict local: stored rating plus stored
/// ancestry is everything ``PolicyEngine`` needs, and it needs no network at all.
///
/// This is the same trade ``PlayEventRecord`` makes and for the same reason. It
/// means a rating that changes in the catalog afterwards is not seen here — which
/// is why the player re-judges against a live verdict immediately before playing,
/// and why that check is not optional.
///
/// ### Lifetime
///
/// Keyed to the favorite that caused it by ``sourceID``/``sourceKind``. Removing
/// that favorite removes these; a song reachable from two kept things has two
/// rows and survives losing one, which is what a reference count would have
/// bought at the price of being wrong after a half-finished walk.
///
/// Derived, and therefore **exempt from a retention sweep for the same reason
/// favorites are** — it is not history, and nothing about "delete my logs" asks
/// for a child's library to shrink. It goes with ``Kid/deleteEverything(at:)``
/// and stays through ``Kid/deleteHistory(at:)``. That is the opposite of
/// ``RecentTrailRecord``, which is derived from *events* and therefore goes when
/// they do; what a projection follows is its source, not its derivedness.
@Model
public final class LibraryIndexRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// Always an Apple Music catalog identifier.
    public private(set) var catalogID: String = ""

    /// `ItemKind.rawValue` — `"album"` or `"song"`. Never an artist: an artist is
    /// what a walk starts from, never what it produces.
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

    /// The favorite this row exists because of, and its kind — MusicKit
    /// identifiers are only unique within a type, so neither field means
    /// anything alone.
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

    /// The value form, or `nil` for a row this version cannot read.
    ///
    /// Dropped rather than guessed at, like ``FavoriteRecord/row``: an
    /// unreadable index row costs a tile the kid can still reach another way,
    /// and costs safety nothing.
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

    /// What the engine is told. Local and complete: a stored rating and stored
    /// lineage are everything a verdict needs, which is the point of this table.
    public var policyItem: Item {
        var ancestors: [Ancestor] = []
        if let album = ancestry.album { ancestors.append(Ancestor(id: album)) }
        if let artist = ancestry.artist { ancestors.append(Ancestor(id: artist)) }
        return Item(id: catalogID, rating: rating.rating, ancestors: ancestors)
    }
}

/// Facts about the walk that produced the index.
public enum LibraryIndex {
    /// Bumped when the walk itself changes — a different depth, a different rule
    /// about what is worth indexing — so rows made by an older one can be told
    /// apart and rebuilt.
    ///
    /// The same device ``RecentTrail/version`` is, and it is here for the same
    /// reason: without it there is no way to distinguish "this artist genuinely
    /// has three albums" from "this artist was walked by a version that stopped
    /// at three".
    public static let version = 1
}
