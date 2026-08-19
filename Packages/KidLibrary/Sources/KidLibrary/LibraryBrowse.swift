import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

/// A song plus `ancestry`, the only way to name its album/artist offline.
public struct LibrarySong: Sendable, Hashable, Identifiable {
    public let item: CatalogItem
    public let ancestry: LibraryAncestry

    /// True if the kid picked this song, not via a kept record or artist.
    public let isChosen: Bool

    public var id: CatalogID { item.id }

    public init(item: CatalogItem, ancestry: LibraryAncestry = .none, isChosen: Bool = true) {
        self.item = item
        self.ancestry = ancestry
        self.isChosen = isChosen
    }
}

/// The library, judged once; nothing here is a permission — rebuilt per policy.
public struct LibraryContents: Sendable {
    /// Kept songs, fold order: chosen first, then indexed — not display order.
    public let songs: [LibrarySong]

    /// Every artist, alphabetical; a walk can't add one, so no chosen split.
    public let artists: [CatalogItem]

    /// Every album in the library, alphabetical. What a drill-in shows.
    public let albums: [CatalogItem]

    /// Only albums the kid picked, directly or via a chosen song, not a walk.
    public let chosenAlbums: [CatalogItem]

    /// What the engine turned down, kept for the report the way it is everywhere.
    public let blocked: [BlockedItem]

    /// False when the catalog didn't answer; rows are write-time copies.
    public let isResolved: Bool

    public init(
        songs: [LibrarySong],
        artists: [CatalogItem],
        albums: [CatalogItem],
        chosenAlbums: [CatalogItem],
        blocked: [BlockedItem],
        isResolved: Bool
    ) {
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.chosenAlbums = chosenAlbums
        self.blocked = blocked
        self.isResolved = isResolved
    }

    public static let empty = LibraryContents(
        songs: [],
        artists: [],
        albums: [],
        chosenAlbums: [],
        blocked: [],
        isResolved: true
    )

    /// Every song, as the player wants them. What a drill-in shows.
    public var songItems: [CatalogItem] { songs.map(\.item) }

    /// Only songs the kid picked; indexed ones stay reachable under their artist.
    public var chosenSongItems: [CatalogItem] { songs.lazy.filter(\.isChosen).map(\.item) }
}

/// Folds kept songs into containers; pure, never re-judges — can't allow more.
public enum LibraryBrowse {
    /// Merges tiers by id; earlier tiers win — hearted beats indexed beats folded.
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

    /// Distinct albums from songs; a row without lineage yet contributes nothing.
    public static func albums(from songs: [LibrarySong]) -> [CatalogItem] {
        sorted(
            fold(songs) { song in
                guard let id = song.ancestry.album, let name = song.ancestry.albumName else {
                    return nil
                }
                return CatalogItem(
                    id: id,
                    title: name,
                    // The artist as subtitle, matching every other row in the app.
                    subtitle: song.ancestry.artistName,
                    // An album's artwork comes from its first surviving song.
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
                    // nil on purpose: an artist's subtitle would repeat the title.
                    artworkURL: song.ancestry.artistArtworkURL
                )
            }
        )
    }

    /// The albums under one artist.
    public static func albums(from songs: [LibrarySong], by artist: CatalogID) -> [CatalogItem] {
        albums(from: songs.filter { $0.ancestry.artist == artist })
    }

    /// Albums by artist over albums, not songs — catches tracks that never loaded.
    public static func albums(_ albums: [CatalogItem], by artist: CatalogID) -> [CatalogItem] {
        albums.filter { album in album.ancestors.contains { $0.id == artist } }
    }

    /// Songs on an album, track order; unnumbered tracks sort to end by title.
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

    /// Filters title and subtitle, substring match; empty term returns all.
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

    /// Alphabetical — the one list here not most-recent-first.
    public static func sorted(_ items: [CatalogItem]) -> [CatalogItem] {
        items.sorted { left, right in
            let a = sortKey(left.title)
            let b = sortKey(right.title)
            // Falls back to id so equal-named rows don't swap between reads.
            if a != b { return a < b }
            return left.id.rawValue < right.id.rawValue
        }
    }

    /// Folds case/diacritics, drops a leading article — orders what a kid reads.
    public static func sortKey(_ title: String) -> String {
        let folded = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for article in Self.articles where folded.hasPrefix(article) {
            let stripped = String(folded.dropFirst(article.count))
            // "The The" keeps its article rather than becoming empty.
            if !stripped.isEmpty { return stripped }
        }
        return folded
    }

    /// English articles only, a deliberate guess — revisit with storefront two.
    private static let articles = ["the ", "a ", "an "]

    // MARK: -

    /// First wins, keyed by id — most-recent-first callers, so it wins artwork.
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
