import Foundation
import PolicyEngine

/// One item in the signed-in account's library, before it has been matched to
/// the Apple Music catalog.
///
/// Short-lived on purpose. A `LibraryItem` exists only inside the parent admin's
/// seeding flow — it is shown, it is matched, and then either its catalog
/// equivalent goes on a list or it is discarded. Nothing persists a library
/// identifier, and the kid's side of the app never sees one.
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

/// One playlist in the signed-in account's own library.
///
/// Separate from ``LibraryItem`` because a playlist has no code to match on —
/// there is no ISRC or UPC for "a list someone made" — so it can never take the
/// same path. What is done with it instead is to resolve its *tracks*, which do
/// have codes, and keep the name.
public struct LibraryPlaylist: Sendable, Hashable, Identifiable {
    /// The library identifier. Meaningful only for the length of this flow, like
    /// ``LibraryItem/id``.
    public let id: String

    public let name: String
    public let curatorName: String?
    public let trackCount: Int?
    public let artworkURL: URL?

    /// Whether the account holder made this themselves, rather than saving one
    /// Apple published.
    ///
    /// Shown to the parent and nothing more. Both kinds are handled the same
    /// way — the tracks are resolved either way — but "the playlist I built in
    /// 2019" and "New Music Daily" are different things to be picking between,
    /// and a list that does not say which is which is harder to use than it
    /// needs to be.
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

    /// Their songs resolved, but did not agree on one artist.
    ///
    /// A refusal rather than a best guess, and the asymmetry is deliberate: a
    /// suggestion grants reach, so naming the wrong artist here would hand a kid
    /// a catalogue nobody chose. Featuring credits, compilations and a
    /// "Various Artists" grouping all produce exactly this, and all of them are
    /// common in a real library.
    case ambiguous

    /// Nothing of theirs could be matched at all.
    case notInAppleMusic
}

/// Picks the artist a set of resolved songs agrees on.
///
/// Pure, so the rule can be tested without a library, a network or a device.
///
/// **A vote rather than the first answer.** `song.artists.first` is right most of
/// the time and wrong in exactly the cases a family library is full of: a track
/// with a guest credit names the guest, a soundtrack names whoever opened it, and
/// a ripped compilation names "Various Artists". One wrong answer here is not a
/// cosmetic slip — a suggested artist is an allowed artist.
public enum ArtistVote: Sendable {
    /// How many of an artist's songs to resolve before deciding.
    public static let sample = 10

    /// The share of resolved songs that must agree. A strict majority.
    public static let threshold = 0.5

    /// The winner, or `nil` if nothing cleared the bar.
    ///
    /// Empty identifiers are dropped before counting, the way
    /// ``MusicKitCatalogSource/artists(of:)`` drops them: a relationship can come
    /// back with no identifier in it, and counting those together would collapse
    /// every affected artist onto one bogus winner.
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

/// Reads the signed-in account's library, as a shortcut for seeding lists.
///
/// **This does not bound what a parent may allow.** Lists are built by searching
/// the Apple Music catalog — see ``CatalogSource`` — and any catalog item can go
/// on one, owned or not. This type exists so a parent who already owns two
/// hundred suitable records can start from those instead of typing two hundred
/// searches. It saves typing, nothing more, and the kid never browses here.
///
/// What it does enforce is that a seeded pick becomes a *catalog* item before it
/// is stored. Anything with no catalog equivalent — a raw file, a personal
/// upload, a delisted record — is discarded rather than stored. A discard is not
/// a refusal either: the parent can still find that record through catalog
/// search, if Apple Music carries it at all. If it does not, we could never have
/// played it.
///
/// That rule is what keeps the deny list honest. If library identifiers could
/// end up on a list, a deny on an artist would not reach that artist's tracks,
/// because there would be no shared namespace to match on and no catalog
/// ancestry to walk. Resolving everything to the catalog first means there is
/// exactly one namespace, and every rule reaches everything.
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
    ///
    /// The tracks and not the playlist, because the playlist has no code to
    /// match on and its tracks do. What comes back out of the resolve is a set of
    /// catalog songs, which is what a suggested playlist is stored as.
    func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryItem]

    /// The account's artists. Names only — an artist carries no code.
    func libraryArtists(limit: Int) async throws -> [LibraryItem]

    /// Names a library artist in the catalog, by way of their songs.
    ///
    /// **No new matching rule.** A library artist has nothing to match on, but
    /// their songs have ISRCs, and a resolved song already arrives carrying its
    /// catalog artist — `resolveToCatalog` asks for `[.albums, .artists]` and
    /// keeps the identifier as ancestry. So this resolves a sample of their songs
    /// and reads the artist off the results. See ``ArtistVote`` for why it is a
    /// vote and not the first answer.
    func resolveArtist(_ artist: LibraryItem) async throws -> ArtistResolution
}

extension LibrarySource {
    /// A source that cannot read playlists sits these out, the way
    /// ``CatalogSource`` lets a source decline `topSongs(of:)`.
    ///
    /// Defaults rather than requirements because the four below arrived after
    /// the protocol did, and a stub written for list seeding should not have to
    /// grow four methods it will never answer.
    public func libraryPlaylists(limit: Int) async throws -> [LibraryPlaylist] { [] }

    public func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryItem] { [] }

    public func libraryArtists(limit: Int) async throws -> [LibraryItem] { [] }

    public func resolveArtist(_ artist: LibraryItem) async throws -> ArtistResolution {
        .notInAppleMusic
    }
}
