import Foundation
import PolicyEngine

/// One item in the signed-in account's library, before matching to the Apple Music
/// catalog. Short-lived: exists only inside the parent's seeding flow — shown,
/// matched, then either its catalog equivalent goes on a list or it's discarded.
/// Nothing persists a library identifier, and the kid's side never sees one.
public struct LibraryItem: Sendable, Hashable, Identifiable {
    /// The library identifier. Meaningful only for the length of this flow.
    public let id: String

    public let kind: ItemKind
    public let title: String
    public let subtitle: String?
    public let artworkURL: URL?

    /// Recording code, on songs. The handle we match a library song to the
    /// catalog by.
    public let isrc: String?

    /// Product code, on albums. The album equivalent of `isrc`.
    public let upc: String?

    public init(
        id: String,
        kind: ItemKind,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        isrc: String? = nil,
        upc: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.isrc = isrc
        self.upc = upc
    }
}

/// One playlist in the signed-in account's own library. Separate from ``LibraryItem`` because a
/// playlist has no code to match on — no ISRC or UPC for a list someone made — so it can never
/// take the same path. Instead its tracks, which do have codes, are resolved, and the name kept.
public struct LibraryPlaylist: Sendable, Hashable, Identifiable {
    /// The library identifier. Meaningful only for the length of this flow, like
    /// ``LibraryItem/id``.
    public let id: String

    public let name: String
    public let curatorName: String?
    public let trackCount: Int?
    public let artworkURL: URL?

    /// Whether the account holder made this, rather than saving one Apple published.
    /// Shown to the parent only — both kinds resolve tracks the same way, but a
    /// self-made playlist and a curated one are different things to pick between.
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

    /// Their songs resolved, but did not agree on one artist. A refusal, not a best
    /// guess, deliberately: a suggestion grants reach, so naming the wrong artist
    /// hands a kid a catalogue nobody chose. Featuring credits, compilations and
    /// Various Artists all produce this, and all are common in a real library.
    case ambiguous

    /// Nothing of theirs could be matched at all.
    case notInAppleMusic
}

/// Picks the artist a set of resolved songs agrees on. Pure, testable without a library, network or device. A
/// vote, not the first answer: `song.artists.first` is wrong in exactly the cases a real library is full of —
/// a guest credit, a soundtrack, a Various Artists rip. A suggested artist is an allowed artist.
public enum ArtistVote: Sendable {
    /// How many of an artist's songs to resolve before deciding.
    public static let sample = 10

    /// The share of resolved songs that must agree. A strict majority.
    public static let threshold = 0.5

    /// The winner, or `nil` if nothing cleared the bar. Empty identifiers are
    /// dropped before counting, as ``MusicKitCatalogSource/artists(of:)``
    /// drops them: a relationship can come back with none, and counting those
    /// together would collapse every affected artist onto one bogus winner.
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
    /// No recording or product code, so there is nothing to match on. A ripped
    /// CD, a personal upload, a raw file someone dragged in.
    case noIdentifier

    /// It had a code, but Apple Music has no matching release. Regional
    /// availability, a delisted record, a bootleg.
    case notInAppleMusic

    /// Library artists and playlists carry no code that maps to the catalog, so
    /// they cannot be matched at all. A parent reaches an artist by allowing one
    /// of their songs or albums and widening from there.
    case unsupportedKind
}

/// A library item that did not make it, and why. Worth showing rather than
/// silently dropping — a parent who expected their whole library to seed should
/// be able to see what did not and why.
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

    public init(resolved: [CatalogItem], discarded: [DiscardedItem]) {
        self.resolved = resolved
        self.discarded = discarded
    }

    public static let empty = LibraryImport(resolved: [], discarded: [])
}

/// Reads the account's library, a shortcut for seeding lists — not a bound on what a parent may allow: any catalog item can
/// go on a list. Enforces that a seeded pick becomes a catalog item first; anything with no equivalent is discarded, not
/// refused. Keeps the deny list honest: one namespace, so a deny reaches every one of an artist's tracks.
public protocol LibrarySource: Sendable {
    /// Browse the library by kind. Only songs and albums can be matched to the
    /// catalog, so those are what is worth offering.
    func libraryItems(kinds: Set<ItemKind>, limit: Int) async throws -> [LibraryItem]

    /// Search within the library.
    func searchLibrary(term: String, kinds: Set<ItemKind>, limit: Int) async throws -> [LibraryItem]

    /// Match library items to their catalog equivalents, in one batch.
    ///
    /// Batched because a library seed is the one place a parent hands us
    /// hundreds of items at once.
    func resolveToCatalog(_ items: [LibraryItem]) async throws -> LibraryImport

    /// The account's own playlists, Apple's and the account holder's alike.
    func libraryPlaylists(limit: Int) async throws -> [LibraryPlaylist]

    /// One playlist's tracks, as library items ready for ``resolveToCatalog(_:)``.
    /// Tracks, not the playlist: the playlist has no code to match on, its tracks do.
    /// The resolve yields catalog songs — what a suggested playlist is stored as.
    func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryItem]

    /// The account's artists. Names only — an artist carries no code.
    func libraryArtists(limit: Int) async throws -> [LibraryItem]

    /// Names a library artist in the catalog, by way of their songs. No new matching
    /// rule: an artist has nothing to match on, but their songs have ISRCs and a
    /// resolved song carries its catalog artist as ancestry. So this resolves a sample
    /// and reads the artist off the results — see ``ArtistVote`` for why it's a vote.
    func resolveArtist(_ artist: LibraryItem) async throws -> ArtistResolution
}

extension LibrarySource {
    /// A source that cannot read playlists sits these out, as ``CatalogSource`` lets one decline
    /// `topSongs(of:)`. Defaults, not requirements: the four below arrived after the protocol
    /// did, and a stub for list seeding shouldn't have to grow methods it will never answer.
    public func libraryPlaylists(limit: Int) async throws -> [LibraryPlaylist] { [] }

    public func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryItem] { [] }

    public func libraryArtists(limit: Int) async throws -> [LibraryItem] { [] }

    public func resolveArtist(_ artist: LibraryItem) async throws -> ArtistResolution {
        .notInAppleMusic
    }
}
