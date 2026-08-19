import PolicyEngine

/// How many identifiers one lookup may name, per kind — Apple's cap, unlike
/// ``MusicKitCatalogSource/maxSearchLimit`` which caps search results. Callers read rows a
/// family stored, not a paged catalog: a kid's playlist is as long as they made it, and one
/// over-cap request fails whole — an empty playlist for a `.block` kid, a lie about their work.
public enum CatalogFetchLimit {
    /// The most identifiers of `kind` one request may carry.
    public static func maxIDs(for kind: ItemKind) -> Int {
        switch kind {
        case .song: 300
        case .album: 100
        case .artist, .playlist: 25
        }
    }

    /// How many identifiers to ask for at once when watching. Distinct from ``maxIDs(for:)`` (Apple's
    /// ceiling): much smaller, so the first screenful returns before a long list finishes. 316 songs
    /// becomes eleven requests, ~four wall-clock rounds with ``inFlight``. Stays below every per-kind cap.
    public static let pageSize = 30

    /// How many pages to have out at once. Three, not one — a strict queue is slower than the request it
    /// replaced. Three, not all — many requests per open meets a rate limit. Pages start in order, so a
    /// caller yielding snapshots shows only the settled prefix, not one filling in from the middle.
    public static let inFlight = 3

    /// `ids` split into requests each within the cap for `kind`. Order preserved, nothing dropped — every
    /// caller reorders the merged result back to its own sequence; a silently-discarded tail is the same
    /// bug one layer down. Empty in, empty out: Apple Music has no answer for a request for nothing.
    public static func batches<ID>(_ ids: [ID], for kind: ItemKind) -> [[ID]] {
        batches(ids, of: maxIDs(for: kind))
    }

    /// The same split at a size the caller chooses. Separate from the by-kind version: one is Apple's
    /// ceiling, one is how much to ask for at a time, and a caller paging a screen need not know
    /// which cap its identifiers fall under. A page of ``pageSize`` still divides by kind underneath.
    public static func batches<ID>(_ ids: [ID], of size: Int) -> [[ID]] {
        guard size > 0 else { return ids.isEmpty ? [] : [ids] }
        guard ids.count > size else { return ids.isEmpty ? [] : [ids] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }
}
