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
}
