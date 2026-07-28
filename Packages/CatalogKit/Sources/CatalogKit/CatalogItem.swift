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
///
/// **`Codable` is for device-local caches, never for the store.** Anything that
/// goes in the CloudKit zone copies the fields it needs by name — that is what
/// makes a schema change a decision rather than an accident of this type
/// gaining a property. Encoding the whole item is for state a device may throw
/// away and rebuild, which today means the persisted play queue: a value that
/// fails to decode simply means the app opens with nothing loaded, so the shape
/// stays free to change.
public struct CatalogItem: Sendable, Hashable, Identifiable, Codable {
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

    /// How long a song runs, in seconds.
    ///
    /// `nil` for everything that is not a song, and for a song the catalog gave
    /// no length for. Presentation only — nothing about a policy decision reads
    /// it.
    public let duration: TimeInterval?

    /// Where a song sits on its album, as the catalog numbers it.
    ///
    /// Kept rather than derived from position in a list, because the list a kid
    /// sees has had the policy engine through it: track 4 blocked makes the fifth
    /// song the fourth row, and a number counted off the rows would quietly
    /// renumber the record.
    public let trackNumber: Int?

    /// Whether the catalog calls this release a single.
    ///
    /// **Three states, not two.** MusicKit's `Album.isSingle` is itself
    /// optional, so `nil` means "the catalog did not say" and never "no" — the
    /// same shape as `rating`, and the same trap. ``isSingleRelease`` is what
    /// decides; nothing should read this directly.
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

    /// Whether to treat this as a single rather than a record.
    ///
    /// The catalog's own flag when there is one. When there is not, two tracks or
    /// fewer stands in for it — a fallback, and one worth naming as such: which
    /// of the two branches actually decides on a real artist page is
    /// **unmeasured**, because nothing Apple-facing has run yet. If the flag
    /// turns out to arrive on every album, the second line is dead code and can
    /// go; if it never arrives on a relationship fetch, the count is the whole
    /// rule.
    ///
    /// False for anything that is not an album, which carries neither field.
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
