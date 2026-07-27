import Foundation
import PolicyEngine

/// Alias for `PolicyEngine`'s `ContentRating`.
///
/// The MusicKit adapter needs to name this type in the same file where
/// `MusicKit.ContentRating` is in scope, and cannot qualify it as
/// `PolicyEngine.ContentRating` — the module name is shadowed by the
/// `PolicyEngine` struct inside it. Declared here, in a file that does not
/// import MusicKit, where the bare name is unambiguous.
public typealias SandboxContentRating = ContentRating

/// One item as the app displays it, and as the policy engine judges it.
///
/// This is the boundary type: everything above this layer works in these, and
/// nothing above this layer imports MusicKit.
///
/// Always an Apple Music catalog item. Library content reaches the app only by
/// being resolved to its catalog equivalent first — see ``LibrarySource``.
public struct CatalogItem: Sendable, Hashable, Identifiable {
    public let id: CatalogID

    public let title: String

    /// Artist name for a song or album, curator for a playlist. `nil` for an
    /// artist, where it would just repeat the title.
    public let subtitle: String?

    public let artworkURL: URL?

    /// `nil` means the catalog gave us no rating, not that the item is clean.
    public let rating: ContentRating?

    /// Containers this item sits inside, nearest first.
    ///
    /// Often empty straight out of a search: MusicKit does not return
    /// relationships with search results. ``CatalogSource/resolveAncestry(for:)``
    /// fills these in as a batch before anything is judged.
    public let ancestors: [Ancestor]

    public init(
        id: CatalogID,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        rating: ContentRating? = nil,
        ancestors: [Ancestor] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.rating = rating
        self.ancestors = ancestors
    }

    /// The view of this item that the policy engine takes.
    public var policyItem: Item {
        Item(id: id, rating: rating, ancestors: ancestors)
    }

    /// A copy with ancestry attached.
    public func withAncestors(_ ancestors: [Ancestor]) -> CatalogItem {
        CatalogItem(
            id: id,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            rating: rating,
            ancestors: ancestors
        )
    }
}

/// One page of results from a source, before any filtering.
public struct CatalogPage: Sendable, Hashable {
    public let items: [CatalogItem]

    /// Whether the source believes more results exist past this page. When
    /// false, the over-fetch loop stops rather than burning its retries.
    public let hasMore: Bool

    public init(items: [CatalogItem], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }

    public static let empty = CatalogPage(items: [], hasMore: false)
}
