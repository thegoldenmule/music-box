/// Whether a catalog item is marked explicit.
///
/// Mirrors MusicKit's `ContentRating`, which has exactly these two cases and is
/// itself optional. This package deliberately does not import MusicKit — the
/// catalog layer maps between the two — so that policy stays testable without a
/// network, a subscription, or a device.
///
/// A `nil` rating means "no rating available", which is not the same as
/// "clean". See ``UnratedBehavior``.
///
/// Worth remembering when reading any code that consumes this: the rating
/// describes lyrics, not themes. A `.clean` song can still be about anything.
public enum ContentRating: String, Sendable, Codable, Hashable, CaseIterable {
    case clean
    case explicit
}

/// What to do in ``SandboxMode/denyPlusAuto`` when an item carries no rating.
///
/// Research question 3 is still open: we have not measured how often MusicKit
/// returns a `nil` rating. Until someone does, this stays configurable rather
/// than baked in — if `nil` turns out to be common, blocking it makes the app
/// feel broken and allowing it makes the filter meaningless.
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
