/// Codable so ancestry persists; without it a verdict stays provisional.
public struct Ancestor: Hashable, Sendable, Codable {
    public let id: CatalogID
    public let rating: ContentRating?

    public init(id: CatalogID, rating: ContentRating? = nil) {
        self.id = id
        self.rating = rating
    }
}

/// Caller supplies ancestry, so the engine stays pure; the catalog layer batches.
public struct Item: Hashable, Sendable {
    public let id: CatalogID

    /// `nil` means the catalog gave us no rating, not that the item is clean.
    public let rating: ContentRating?

    /// Nearest first: album, artist. inheritFromAncestor takes the first rated one.
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
