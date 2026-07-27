/// The answer to "can this kid see or play this right now?"
///
/// Not a boolean. The reason is what the activity report is made of, and what
/// the message shown to the kid comes from.
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

    /// The parent denied this item or one of its containers. Carries whichever
    /// entry matched, so the report can say *which* deny did it.
    case deniedByParent(CatalogID)

    /// Level 2: the catalog marks this explicit.
    ///
    /// The catalog often carries both an explicit and a clean cut of the same
    /// song. Callers seeing this reason should look for the clean one rather
    /// than pretending the song does not exist — that lookup belongs in the
    /// catalog layer, not here.
    case explicitContent

    /// Level 2: no rating available, and ``UnratedBehavior`` says to block.
    case unrated
}
