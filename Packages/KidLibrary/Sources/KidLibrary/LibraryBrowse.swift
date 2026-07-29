import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

/// One song in the kid's library, with what it knows about where it came from.
///
/// The pairing exists because the two halves come from different places and both
/// are needed at once: `item` is resolved against the catalog and judged, while
/// `ancestry` is the copy made at write time and is the only thing that can name
/// an album or an artist without a request.
public struct LibrarySong: Sendable, Hashable, Identifiable {
    public let item: CatalogItem
    public let ancestry: LibraryAncestry

    public var id: CatalogID { item.id }

    public init(item: CatalogItem, ancestry: LibraryAncestry = .none) {
        self.item = item
        self.ancestry = ancestry
    }
}

/// The whole of the kid's library, resolved and judged once.
///
/// **One value rather than five reads.** Every column in the browser — artists,
/// albums, songs, and each drill-in below them — is a filter of this, computed
/// with no request and no `await`. That is what lets a filter field narrow a list
/// as a child types and what lets tapping an artist show their albums instantly
/// rather than after a spinner.
///
/// Everything in `songs` has already been through the policy engine. Nothing here
/// is a permission: a parent may deny tomorrow what is in this value today, which
/// is why it is rebuilt on every policy change rather than cached across one.
public struct LibraryContents: Sendable {
    /// Every kept song the kid may still play.
    ///
    /// **Fold order, not display order.** What the kid chose comes first, most
    /// recent first, and what a walk indexed follows in a stable order behind it
    /// — which is what makes ``LibraryBrowse/albums(from:)`` take a container's
    /// artwork from a hand-picked song where there is one. A column showing these
    /// sorts them itself; see ``LibraryBrowse/sorted(_:)``.
    public let songs: [LibrarySong]

    /// Every artist, alphabetical. Favorited ones and ones folded from `songs`.
    public let artists: [CatalogItem]

    /// Every album, alphabetical. Favorited ones and ones folded from `songs`.
    public let albums: [CatalogItem]

    /// What the engine turned down, kept for the report the way it is everywhere.
    public let blocked: [BlockedItem]

    /// False when the catalog did not answer and the rows were drawn from the
    /// copies made at write time. See ``LibraryResults/isResolved``.
    public let isResolved: Bool

    public init(
        songs: [LibrarySong],
        artists: [CatalogItem],
        albums: [CatalogItem],
        blocked: [BlockedItem],
        isResolved: Bool
    ) {
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.blocked = blocked
        self.isResolved = isResolved
    }

    public static let empty = LibraryContents(
        songs: [],
        artists: [],
        albums: [],
        blocked: [],
        isResolved: true
    )

    /// The songs, as the player wants them.
    public var songItems: [CatalogItem] { songs.map(\.item) }
}

/// Turns the kid's kept songs into the artist and album columns above them.
///
/// Pure — no I/O, no clock, no throwing path — for the same reason
/// ``PolicyEngine`` is: it is the part worth testing exhaustively, and the whole
/// point of copying ancestry onto the stored row was to make this computable
/// with nothing but rows already in hand.
///
/// **A container here is a folder, not a catalog item, and is deliberately never
/// judged on its own.** The songs it is folded from have already been through the
/// engine carrying their real lineage and their real rating, so an album the
/// parent denied — or an explicit one — has no surviving songs to be folded from
/// and no row appears. Judging the folded row instead would mean judging a
/// synthesised `CatalogItem` whose rating is `nil` because nobody asked the
/// catalog, and with ``UnratedBehavior/block`` as the default that would empty
/// the Albums column for every kid in the ordinary case. The asymmetry is the
/// point: this fold cannot reach anything its input did not already allow.
public enum LibraryBrowse {
    /// The same container from several places, as one row, alphabetical.
    ///
    /// **Earlier tiers win**, and the order callers pass them in is the order of
    /// how much a row knows about itself: something the kid hearted was resolved
    /// against the catalog and carries its real rating and the catalog's own
    /// artwork; something the walk indexed carries what the catalog said then;
    /// something folded out of a song carries only a name copied at write time.
    /// Hearting *25*, hearting a song from *25*, and hearting the artist is one
    /// row, and it is the hearted one.
    public static func merged(_ tiers: [CatalogItem]...) -> [CatalogItem] {
        var seen: Set<CatalogID> = []
        var out: [CatalogItem] = []
        for tier in tiers {
            for item in tier where seen.insert(item.id).inserted {
                out.append(item)
            }
        }
        return sorted(out)
    }

    /// Every distinct album across these songs, alphabetical.
    ///
    /// A song contributes an album only when the ancestry names one. A row that
    /// has not been topped up yet contributes nothing rather than an untitled
    /// placeholder — a column of blanks is worse than a shorter column, and the
    /// next read fixes it.
    public static func albums(from songs: [LibrarySong]) -> [CatalogItem] {
        sorted(
            fold(songs) { song in
                guard let id = song.ancestry.album, let name = song.ancestry.albumName else {
                    return nil
                }
                return CatalogItem(
                    id: id,
                    title: name,
                    // The artist, so an album row reads the way it does everywhere
                    // else in the app.
                    subtitle: song.ancestry.artistName,
                    // An album's artwork is its songs' artwork in Apple Music, so
                    // the first surviving song's is the album's and no second URL
                    // has to be stored.
                    artworkURL: song.item.artworkURL,
                    ancestors: song.ancestry.artist.map { [Ancestor(id: $0)] } ?? []
                )
            }
        )
    }

    /// Every distinct artist across these songs, alphabetical.
    public static func artists(from songs: [LibrarySong]) -> [CatalogItem] {
        sorted(
            fold(songs) { song in
                guard let id = song.ancestry.artist, let name = song.ancestry.artistName else {
                    return nil
                }
                return CatalogItem(
                    id: id,
                    title: name,
                    // `nil` on purpose: an artist's subtitle would repeat the
                    // title. See `CatalogItem.subtitle`.
                    artworkURL: song.ancestry.artistArtworkURL
                )
            }
        )
    }

    /// The albums under one artist.
    public static func albums(from songs: [LibrarySong], by artist: CatalogID) -> [CatalogItem] {
        albums(from: songs.filter { $0.ancestry.artist == artist })
    }

    /// The songs on one album, in track order where the catalog numbered them.
    ///
    /// Track order and not alphabetical: a record has an order, and it is the one
    /// thing about an album a kid already knows. Anything unnumbered sorts to the
    /// end by title rather than to the front by accident.
    public static func songs(from songs: [LibrarySong], on album: CatalogID) -> [CatalogItem] {
        songs
            .filter { $0.ancestry.album == album }
            .map(\.item)
            .sorted { left, right in
                switch (left.trackNumber, right.trackNumber) {
                case let (l?, r?) where l != r: return l < r
                case (nil, .some): return false
                case (.some, nil): return true
                default: return sortKey(left.title) < sortKey(right.title)
                }
            }
    }

    /// The songs under one artist, alphabetical.
    public static func songs(from songs: [LibrarySong], by artist: CatalogID) -> [CatalogItem] {
        sorted(songs.filter { $0.ancestry.artist == artist }.map(\.item))
    }

    // MARK: - Filtering

    /// The filter field's predicate: case- and diacritic-insensitive, over what
    /// is actually on the row.
    ///
    /// Title **and** subtitle, so typing an artist's name narrows a list of
    /// songs — which is most of what a child types. Substring rather than prefix
    /// for the same reason: a kid who remembers one word of a title should find
    /// it wherever the word sits.
    ///
    /// An empty term is the whole list, not nothing.
    public static func filter(_ items: [CatalogItem], by term: String) -> [CatalogItem] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return items.filter {
            if $0.title.range(of: trimmed, options: options) != nil { return true }
            return $0.subtitle?.range(of: trimmed, options: options) != nil
        }
    }

    // MARK: - Ordering

    /// Alphabetical the way a person reading a list means it.
    ///
    /// **The one read on this type that is not most-recent-first.** Every other
    /// list in the library is ordered by `favoritedAt` or `modifiedAt` descending,
    /// because a shelf is about what the kid just did. A column you scan for a
    /// name is about the name.
    public static func sorted(_ items: [CatalogItem]) -> [CatalogItem] {
        items.sorted { left, right in
            let a = sortKey(left.title)
            let b = sortKey(right.title)
            // Falls back to the identifier so the order is total: two records
            // with the same name must not swap places between two reads of the
            // same data.
            if a != b { return a < b }
            return left.id.rawValue < right.id.rawValue
        }
    }

    /// Case- and diacritic-folded, with a leading article dropped.
    ///
    /// So *The Beatles* files under B, *Ólafur* next to *Olafur*, and *the xx*
    /// does not lead the column. Folding is `.current` locale on purpose — this
    /// orders a list a child is reading, not a stored key anything compares
    /// across devices.
    public static func sortKey(_ title: String) -> String {
        let folded = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for article in Self.articles where folded.hasPrefix(article) {
            let stripped = String(folded.dropFirst(article.count))
            // "The The" keeps its article rather than becoming empty, and so does
            // a band actually called "A".
            if !stripped.isEmpty { return stripped }
        }
        return folded
    }

    /// English only, and knowingly so. Apple Music's catalog is international and
    /// this is a guess that happens to be right for most of what a kid in a US
    /// storefront will keep — the same class of assumption as the storefront
    /// itself. Worth revisiting when there is a second storefront to be wrong in.
    private static let articles = ["the ", "a ", "an "]

    // MARK: -

    /// First one wins, keyed by identifier.
    ///
    /// Which matters: the first is the earliest in whatever order the caller
    /// handed over, and callers hand songs over most-recent-first, so the artwork
    /// and subtitle on a folded row come from the most recently kept song on that
    /// record rather than from an arbitrary one.
    private static func fold(
        _ songs: [LibrarySong],
        _ container: (LibrarySong) -> CatalogItem?
    ) -> [CatalogItem] {
        var seen: Set<CatalogID> = []
        var out: [CatalogItem] = []
        for song in songs {
            guard let made = container(song), seen.insert(made.id).inserted else { continue }
            out.append(made)
        }
        return out
    }
}
