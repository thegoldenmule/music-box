import PolicyEngine

/// How many identifiers one catalog lookup may name, per kind.
///
/// A sibling of ``MusicKitCatalogSource/maxSearchLimit`` and a different ceiling
/// entirely: that one caps how many *results* a search may ask for, this one
/// caps how many *identifiers* a by-id lookup may send. Both are hard — over the
/// line is a `400`, not a short answer — and both are per-endpoint rather than
/// global, which is why this is a function of the kind and not one number.
///
/// The numbers are Apple's, from the Apple Music API reference for the
/// `ids` parameter of each *Get Multiple Catalog …* endpoint:
///
/// | Kind | Cap |
/// | --- | --- |
/// | song | 300 |
/// | album | 100 |
/// | artist | 25 |
/// | playlist | 25 |
///
/// This exists because the callers are not paging through a catalog, they are
/// reading rows the family already stored, and that count is theirs rather than
/// ours: a kid's playlist is as long as they made it. A 316-song playlist sent
/// as one request is over the song cap, and the whole read fails — which for a
/// kid whose `unratedBehavior` is `.block` renders as an empty playlist,
/// because an unresolved song has no rating and an unrated song is blocked. The
/// screen then says the child has nothing in there, which is a lie about their
/// own work. Splitting is what keeps the request legal at any list length.
public enum CatalogFetchLimit {
    /// The most identifiers of `kind` one request may carry.
    public static func maxIDs(for kind: ItemKind) -> Int {
        switch kind {
        case .song: 300
        case .album: 100
        case .artist, .playlist: 25
        }
    }

    /// How many identifiers to ask for at once when somebody is watching.
    ///
    /// **A different question from the cap above, and much smaller.**
    /// ``maxIDs(for:)`` is what Apple permits; this is what a screen wants. A
    /// three-hundred-song playlist asked for in one request shows nothing at all
    /// until every one of them is back, and the kid is looking at the first ten.
    /// Thirty is about a screenful and a half, so the first request is the one
    /// that fills the view and the rest arrive underneath it.
    ///
    /// Small enough to be worth splitting, large enough that a long list is not
    /// a hundred round trips: 316 songs is eleven requests rather than one, and
    /// with ``inFlight`` of them running the wall clock is about four.
    ///
    /// Below every cap in the table above, deliberately — a page of thirty
    /// mixed identifiers cannot breach even the artist limit of 25 once
    /// `items(for:)` has grouped it by kind, because the by-kind split still
    /// runs underneath and would divide it again.
    public static let pageSize = 30

    /// How many pages to have out at once.
    ///
    /// Three rather than one, because a strict queue makes a long list slower
    /// than the single request it replaced — eleven round trips end to end. And
    /// three rather than all of them, because eleven simultaneous requests every
    /// time a playlist opens is the shape that meets a rate limit.
    ///
    /// Pages are still *started* in order, and a caller yielding snapshots
    /// should only ever show the settled prefix — the top is what is on screen,
    /// and a list that fills in from the middle reorders under a reader's eyes.
    public static let inFlight = 3

    /// `ids` split into requests that are each within the cap for `kind`.
    ///
    /// Order is preserved and nothing is dropped: every caller of this reorders
    /// the merged result back to its own sequence, and a lookup that quietly
    /// discarded the tail would be the same bug one layer down.
    ///
    /// Empty in, empty out — an empty batch is a request for nothing, and
    /// sending it asks Apple Music a question with no answer.
    public static func batches<ID>(_ ids: [ID], for kind: ItemKind) -> [[ID]] {
        batches(ids, of: maxIDs(for: kind))
    }

    /// The same split at a size the caller chooses.
    ///
    /// Separate from the by-kind version because the two answer different
    /// questions — one is Apple's ceiling and one is how much to ask for at a
    /// time — and a caller paging for a screen must not have to know which cap
    /// its identifiers happen to fall under. Both still apply: a page of
    /// ``pageSize`` goes on to be divided by kind underneath if it has to be.
    public static func batches<ID>(_ ids: [ID], of size: Int) -> [[ID]] {
        guard size > 0 else { return ids.isEmpty ? [] : [ids] }
        guard ids.count > size else { return ids.isEmpty ? [] : [ids] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }
}
