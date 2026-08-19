/// A container an item sits inside, and its rating if it has one. `Codable`
/// because ancestry travels with anything written down — the persisted play
/// queue forced it: ancestry makes a verdict final rather than provisional, so
/// a stored item without ancestors must go back to the network to be judged.
public struct Ancestor: Hashable, Sendable, Codable {
    public let id: CatalogID
    public let rating: ContentRating?

    public init(id: CatalogID, rating: ContentRating? = nil) {
        self.id = id
        self.rating = rating
    }
}

/// One catalog item being judged, with the containers it sits inside. The
/// caller supplies ancestry, deliberately: the engine stays synchronous and
/// free of I/O, and the catalog layer is the one place that can batch lookups.
public struct Item: Hashable, Sendable {
    public let id: CatalogID

    /// `nil` means the catalog gave us no rating, not that the item is clean.
    public let rating: ContentRating?

    /// Containers this item belongs to, **nearest first**: album, then artist,
    /// plus the playlist it is played from when there is one. Order matters for
    /// ``UnratedBehavior/inheritFromAncestor``, which takes the first rated one.
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
