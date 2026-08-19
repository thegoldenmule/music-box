import Foundation
import PolicyEngine

/// Alias needed: module `PolicyEngine` is shadowed by the struct of the same name.
public typealias SandboxContentRating = ContentRating

/// The MusicKit boundary type; `Codable` is for local caches, not CloudKit.
public struct CatalogItem: Sendable, Hashable, Identifiable, Codable {
    public let id: CatalogID

    public let title: String

    /// Artist or curator name; nil for an artist, where it'd repeat the title.
    public let subtitle: String?

    public let artworkURL: URL?

    /// `nil` means the catalog gave us no rating, not that the item is clean.
    public let rating: ContentRating?

    /// Nearest first; empty from search until resolveAncestry(for:) fills them in.
    public let ancestors: [Ancestor]

    /// Seconds, songs only; presentation only, no policy decision reads it.
    public let duration: TimeInterval?

    /// Catalog track number, not row position — blocking one renumbers the rest.
    public let trackNumber: Int?

    /// Three states like `rating`; nil means unsaid. isSingleRelease decides.
    public let isSingle: Bool?

    /// Catalog's own track count, regardless of what the kid actually sees.
    public let trackCount: Int?

    public init(
        id: CatalogID,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        rating: ContentRating? = nil,
        ancestors: [Ancestor] = [],
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil,
        isSingle: Bool? = nil,
        trackCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.rating = rating
        self.ancestors = ancestors
        self.duration = duration
        self.trackNumber = trackNumber
        self.isSingle = isSingle
        self.trackCount = trackCount
    }

    /// Catalog flag if present, else ≤2 tracks; fallback frequency is unmeasured.
    public var isSingleRelease: Bool {
        if let isSingle { return isSingle }
        if let trackCount { return trackCount <= 2 }
        return false
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
            ancestors: ancestors,
            duration: duration,
            trackNumber: trackNumber,
            isSingle: isSingle,
            trackCount: trackCount
        )
    }
}

/// One page of results from a source, before any filtering.
public struct CatalogPage: Sendable, Hashable {
    public let items: [CatalogItem]

    /// False stops the over-fetch loop rather than burning retries.
    public let hasMore: Bool

    public init(items: [CatalogItem], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }

    public static let empty = CatalogPage(items: [], hasMore: false)
}
