/// Mirrors MusicKit's `ContentRating` without importing it, so policy stays pure.
public enum ContentRating: String, Sendable, Codable, Hashable, CaseIterable {
    case clean
    case explicit
}

/// Configurable: how often MusicKit omits a rating is unmeasured (research Q3).
public enum UnratedBehavior: String, Sendable, Codable, Hashable, CaseIterable {
    /// Treat unrated as safe. Only sensible if `nil` turns out to be rare.
    case allow

    /// Treat unrated as explicit. Conservative, and the default.
    case block

    /// Falls back to nearest rated ancestor; blocks if no ancestor is rated either.
    case inheritFromAncestor
}
