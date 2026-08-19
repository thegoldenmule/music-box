import Foundation
import PolicyEngine

/// Alias for `PolicyEngine`'s `ContentRating`. The MusicKit adapter needs this type in
/// scope in the same file as `MusicKit.ContentRating`, and can't qualify it
/// `PolicyEngine.ContentRating` — the module name is shadowed by the `PolicyEngine` struct
/// inside it. Declared here, where no MusicKit import leaves the bare name unambiguous.
public typealias SandboxContentRating = ContentRating

/// One item as the app displays it and the policy engine judges it — the boundary type: nothing above imports MusicKit.
/// Always a catalog item; library content arrives only resolved, see ``LibrarySource``. `Codable` is for device-local
/// caches, not the store: the CloudKit zone copies fields by name so a schema change stays a decision, not an accident.
public struct CatalogItem: Sendable, Hashable, Identifiable, Codable {
    public let id: CatalogID

    public let title: String

    /// Artist name for a song or album, curator for a playlist. `nil` for an
    /// artist, where it would just repeat the title.
    public let subtitle: String?

    public let artworkURL: URL?

    /// `nil` means the catalog gave us no rating, not that the item is clean.
    public let rating: ContentRating?

    /// Containers this item sits inside, nearest first. Often empty straight out
    /// of a search: MusicKit returns no relationships with search results.
    /// ``CatalogSource/resolveAncestry(for:)`` fills these in as a batch before anything is judged.
    public let ancestors: [Ancestor]

    /// How long a song runs, in seconds. `nil` for everything that
    /// isn't a song, and for a song the catalog gave no length for.
    /// Presentation only — nothing about a policy decision reads it.
    public let duration: TimeInterval?

    /// Where a song sits on its album, as the catalog numbers it. Kept, not derived from
    /// list position: the list a kid sees has had the engine through it — track 4 blocked
    /// makes song 5 the fourth row, and counting off rows would quietly renumber the record.
    public let trackNumber: Int?

    /// Whether the catalog calls this release a single. Three states, not two:
    /// MusicKit's `Album.isSingle` is itself optional, so `nil` means the
    /// catalog didn't say, never no — the same shape and trap as `rating`.
    /// ``isSingleRelease`` decides; nothing should read this directly.
    public let isSingle: Bool?

    /// How many tracks the catalog says a release has, whatever the kid may
    /// actually see of it.
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

    /// Whether to treat this as a single rather than a record. The catalog's own flag when there is one; otherwise two
    /// tracks or fewer stands in — a fallback whose actual role is unmeasured. If the flag always arrives, the fallback is
    /// dead code; if it never does, the count is the whole rule. False for anything that isn't an album.
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

    /// Whether the source believes more results exist past this page. When
    /// false, the over-fetch loop stops rather than burning its retries.
    public let hasMore: Bool

    public init(items: [CatalogItem], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }

    public static let empty = CatalogPage(items: [], hasMore: false)
}
