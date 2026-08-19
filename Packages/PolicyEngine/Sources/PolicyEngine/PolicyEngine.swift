/// Decides what one kid may see or play; every surface must ask this.
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
        // Deny wins in every mode; a deny on a container reaches everything inside.
        if let match = firstDenied(item) {
            return .blocked(.deniedByParent(match))
        }

        switch policy.mode {
        case .reportOnly:
            // Rule 2. No walls. Activity is still logged by the caller.
            return .allowed

        case .allowOnly:
            // Level 1: no rating check — a parent hand-pick means it either way.
            return isListedAllowed(item) ? .allowed : .blocked(.notOnAllowList)

        case .denyPlusAuto:
            // Level 2: item-level allow overrides rating; container-level allow does not.
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
        // Containers carry no rating; skip them or unratedBehavior hides them all.
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
                // inheritFromAncestor already tried in effectiveRating and found nothing.
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
