/// Whether a catalog item is marked explicit. Mirrors MusicKit's `ContentRating`
/// without importing it — the catalog layer maps between the two — so policy is
/// testable with no network, subscription, or device. `nil` is "no rating", not
/// clean: see ``UnratedBehavior``. Ratings describe lyrics, not themes.
public enum ContentRating: String, Sendable, Codable, Hashable, CaseIterable {
    case clean
    case explicit
}

/// What to do in ``SandboxMode/denyPlusAuto`` when an item carries no rating.
/// Configurable rather than baked in while research question 3 — how often
/// MusicKit returns `nil` — stays unmeasured: if `nil` is common, blocking
/// makes the app feel broken and allowing makes the filter meaningless.
public enum UnratedBehavior: String, Sendable, Codable, Hashable, CaseIterable {
    /// Treat unrated as safe. Only sensible if `nil` turns out to be rare.
    case allow

    /// Treat unrated as explicit. Conservative, and the default.
    case block

    /// Fall back to the nearest ancestor that does carry a rating, so an
    /// unrated track on an explicit album is treated as explicit. Blocks when
    /// no ancestor is rated either.
    case inheritFromAncestor
}
