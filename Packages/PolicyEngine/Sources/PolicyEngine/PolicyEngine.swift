/// Decides what one kid may see or play. Every surface asks this; nothing else
/// decides, and the player asks again immediately before playback rather than
/// trusting the UI — shown but then refused is a UI bug, not a safety failure.
/// Build one per kid and reuse it: the constructor indexes the lists once.
public struct PolicyEngine: Sendable {
    public let policy: Policy

    private let allowed: Set<CatalogID>
    private let denied: Set<CatalogID>

    public init(policy: Policy) {
        self.policy = policy

        var allowed: Set<CatalogID> = []
        var denied: Set<CatalogID> = []
        for entry in policy.entries {
            switch entry.kind {
            case .allow: allowed.insert(entry.id)
            case .deny: denied.insert(entry.id)
            }
        }
        self.allowed = allowed
        self.denied = denied
    }

    /// Judge one item. Synchronous, no I/O — the caller supplies ancestry.
    public func evaluate(_ item: Item) -> Verdict {
        // Rule 1. Deny wins, in every mode, and a deny on a container reaches
        // everything inside it. A parent who denied an artist and separately
        // allowed one of their songs meant the deny.
        if let match = firstDenied(item) {
            return .blocked(.deniedByParent(match))
        }

        switch policy.mode {
        case .reportOnly:
            // Rule 2. No walls. Activity is still logged by the caller.
            return .allowed

        case .allowOnly:
            // Rule 3. No rating check here: if a parent hand-picked it, they
            // meant it, explicit or not.
            return isListedAllowed(item) ? .allowed : .blocked(.notOnAllowList)

        case .denyPlusAuto:
            // Rule 4. An allow on the item *itself* overrides the rating check
            // — the per-item override. An allow on a container does not, so
            // "allow this artist" cannot silently permit their next explicit
            // release.
            if allowed.contains(item.id) {
                return .allowed
            }
            return ratingVerdict(for: item)
        }
    }

    // MARK: - Rules

    /// The item itself, or the nearest container, that the parent denied.
    private func firstDenied(_ item: Item) -> CatalogID? {
        if denied.contains(item.id) {
            return item.id
        }
        return item.ancestors.first { denied.contains($0.id) }?.id
    }

    private func isListedAllowed(_ item: Item) -> Bool {
        if allowed.contains(item.id) {
            return true
        }
        return item.ancestors.contains { allowed.contains($0.id) }
    }

    private func ratingVerdict(for item: Item) -> Verdict {
        // Artists and playlists are containers and carry no rating — MusicKit's
        // `Playlist` has no `contentRating` at all. They may appear; what is
        // inside is judged track by track as it comes up. Without this,
        // `UnratedBehavior.block` would hide every artist and playlist.
        switch item.id.kind {
        case .artist, .playlist:
            return .allowed
        case .album, .song:
            break
        }

        switch effectiveRating(for: item) {
        case .clean:
            return .allowed
        case .explicit:
            return .blocked(.explicitContent)
        case nil:
            switch policy.unratedBehavior {
            case .allow:
                return .allowed
            case .block, .inheritFromAncestor:
                // `inheritFromAncestor` already had its chance in
                // `effectiveRating` and found nothing. Fall back to blocking.
                return .blocked(.unrated)
            }
        }
    }

    private func effectiveRating(for item: Item) -> ContentRating? {
        if let rating = item.rating {
            return rating
        }
        guard policy.unratedBehavior == .inheritFromAncestor else {
            return nil
        }
        return item.ancestors.lazy.compactMap(\.rating).first
    }
}
