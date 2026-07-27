/// A container an item sits inside, and its rating if it has one.
public struct Ancestor: Hashable, Sendable {
    public let id: CatalogID
    public let rating: ContentRating?

    public init(id: CatalogID, rating: ContentRating? = nil) {
        self.id = id
        self.rating = rating
    }
}

/// One catalog item being judged, together with the containers it sits inside.
///
/// The caller is responsible for supplying ancestry. That is deliberate: the
/// engine stays synchronous and free of I/O, and the catalog layer is the one
/// place that knows how to batch those lookups.
public struct Item: Hashable, Sendable {
    public let id: CatalogID

    /// `nil` means the catalog gave us no rating, not that the item is clean.
    public let rating: ContentRating?

    /// Containers this item belongs to, **nearest first**: a song's album, then
    /// its artist, plus the playlist it is being played from when there is one.
    ///
    /// Order matters for ``UnratedBehavior/inheritFromAncestor``, which takes
    /// the first ancestor that carries a rating.
    public let ancestors: [Ancestor]

    public init(
        id: CatalogID,
        rating: ContentRating? = nil,
        ancestors: [Ancestor] = []
    ) {
        self.id = id
        self.rating = rating
        self.ancestors = ancestors
    }
}
