import Foundation
import PolicyEngine

/// Short-lived seeding value; no library identifier is ever persisted or shown.
public struct LibraryItem: Sendable, Hashable, Identifiable {
    /// The library identifier. Meaningful only for the length of this flow.
    public let id: String

    public let kind: ItemKind
    public let title: String
    public let subtitle: String?
    public let artworkURL: URL?

    /// ISRC — the handle a library song is matched to the catalog by.
    public let isrc: String?

    /// Product code, on albums. The album equivalent of `isrc`.
    public let upc: String?

    /// The album a song sits on, by name; a resolved song carries only the id.
    public let albumTitle: String?

    /// When the account added it; what a library shelf orders by.
    public let addedAt: Date?

    public init(
        id: String,
        kind: ItemKind,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        isrc: String? = nil,
        upc: String? = nil,
        albumTitle: String? = nil,
        addedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.isrc = isrc
        self.upc = upc
        self.albumTitle = albumTitle
        self.addedAt = addedAt
    }
}

/// Separate from LibraryItem: a playlist has no code, so its tracks match instead.
public struct LibraryPlaylist: Sendable, Hashable, Identifiable {
    /// Library id, meaningful only for this flow — like ``LibraryItem/id``.
    public let id: String

    public let name: String
    public let curatorName: String?
    public let trackCount: Int?
    public let artworkURL: URL?

    /// Self-made vs. Apple-curated; shown to the parent, resolution is unaffected.
    public let isPersonal: Bool

    public init(
        id: String,
        name: String,
        curatorName: String? = nil,
        trackCount: Int? = nil,
        artworkURL: URL? = nil,
        isPersonal: Bool
    ) {
        self.id = id
        self.name = name
        self.curatorName = curatorName
        self.trackCount = trackCount
        self.artworkURL = artworkURL
        self.isPersonal = isPersonal
    }
}

/// What came of trying to name a library artist in the catalog.
public enum ArtistResolution: Sendable, Hashable {
    case resolved(CatalogItem)

    /// Songs disagreed on an artist — a refusal, since a wrong guess grants reach.
    case ambiguous

    /// Nothing of theirs could be matched at all.
    case notInAppleMusic
}

/// A vote, not `song.artists.first` — wrong for guest credits and Various Artists.
public enum ArtistVote: Sendable {
    /// How many of an artist's songs to resolve before deciding.
    public static let sample = 10

    /// The share of resolved songs that must agree. A strict majority.
    public static let threshold = 0.5

    /// Empty ids drop before counting, or artists collapse onto one bogus winner.
    public static func winner(among songs: [CatalogItem]) -> CatalogID? {
        var counts: [CatalogID: Int] = [:]
        var voters = 0
        for song in songs {
            guard
                let artist = song.ancestors.first(where: { $0.id.kind == .artist })?.id,
                !artist.rawValue.isEmpty
            else { continue }
            counts[artist, default: 0] += 1
            voters += 1
        }
        guard voters > 0, let best = counts.max(by: { $0.value < $1.value }) else { return nil }
        return Double(best.value) > Double(voters) * threshold ? best.key : nil
    }
}

/// Why a library item could not be put on a list.
public enum DiscardReason: String, Sendable, Hashable, CaseIterable {
    /// No code to match on — a ripped CD, upload, or dragged-in file.
    case noIdentifier

    /// Had a code but no match — regional gap, delisted, or bootleg.
    case notInAppleMusic

    /// Artists/playlists carry no code; a parent reaches one via a song or album.
    case unsupportedKind
}

/// Shown, not silently dropped — a parent expects to see what didn't seed and why.
public struct DiscardedItem: Sendable, Hashable {
    public let item: LibraryItem
    public let reason: DiscardReason

    public init(item: LibraryItem, reason: DiscardReason) {
        self.item = item
        self.reason = reason
    }
}

/// The outcome of matching a batch of library items against the catalog.
public struct LibraryImport: Sendable, Hashable {
    /// Catalog items, ready to go on an allow or deny list.
    public let resolved: [CatalogItem]

    /// What could not be matched.
    public let discarded: [DiscardedItem]

    /// The match per library id. `resolved` loses input order and collapses two
    /// library items sharing a code; this keeps both, for a caller that needs
    /// to walk its own list and read each item's date off the library side.
    public let matches: [String: CatalogItem]

    public init(
        resolved: [CatalogItem],
        discarded: [DiscardedItem],
        matches: [String: CatalogItem] = [:]
    ) {
        self.resolved = resolved
        self.discarded = discarded
        self.matches = matches
    }

    public static let empty = LibraryImport(resolved: [], discarded: [])
}

/// Seeding shortcut, not a bound on allow; a pick becomes an item or is discarded.
public protocol LibrarySource: Sendable {
    /// Songs and albums only — the only kinds that can match the catalog.
    /// Newest additions first, so a capped read keeps what was added last.
    func libraryItems(kinds: Set<ItemKind>, limit: Int, offset: Int) async throws -> [LibraryItem]

    /// Search within the library.
    func searchLibrary(term: String, kinds: Set<ItemKind>, limit: Int) async throws -> [LibraryItem]

    /// Batched — the one place a parent hands us hundreds of items at once.
    func resolveToCatalog(_ items: [LibraryItem]) async throws -> LibraryImport

    /// The account's own playlists, Apple's and the account holder's alike.
    func libraryPlaylists(limit: Int) async throws -> [LibraryPlaylist]

    /// Tracks, not the playlist — it has no code; resolve yields catalog songs.
    func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryItem]

    /// The account's artists. Names only — an artist carries no code.
    func libraryArtists(limit: Int) async throws -> [LibraryItem]

    /// Names an artist via their songs' ISRCs and ancestry — see ``ArtistVote``.
    func resolveArtist(_ artist: LibraryItem) async throws -> ArtistResolution
}

extension LibrarySource {
    /// The first page; seeding only ever wanted one.
    public func libraryItems(kinds: Set<ItemKind>, limit: Int) async throws -> [LibraryItem] {
        try await libraryItems(kinds: kinds, limit: limit, offset: 0)
    }

    /// Defaults, not requirements, added later — like `topSongs(of:)` elsewhere.
    public func libraryPlaylists(limit: Int) async throws -> [LibraryPlaylist] { [] }

    public func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryItem] { [] }

    public func libraryArtists(limit: Int) async throws -> [LibraryItem] { [] }

    public func resolveArtist(_ artist: LibraryItem) async throws -> ArtistResolution {
        .notInAppleMusic
    }
}
