/// Not a boolean: the reason feeds the activity report and the kid's message.
public enum Verdict: Hashable, Sendable {
    case allowed
    case blocked(Reason)

    public var isAllowed: Bool {
        self == .allowed
    }

    /// Why this was blocked, or `nil` when it was allowed.
    public var reason: Reason? {
        switch self {
        case .allowed: nil
        case .blocked(let reason): reason
        }
    }
}

/// Why an item was blocked.
public enum Reason: Hashable, Sendable {
    /// Level 1: the parent never added this, or anything containing it.
    case notOnAllowList

    /// Carries whichever deny entry matched, so the report can say which one.
    case deniedByParent(CatalogID)

    /// Often a clean cut exists too — look it up in the catalog, don't hide it.
    case explicitContent

    /// Level 2: no rating available, and ``UnratedBehavior`` says to block.
    case unrated
}
