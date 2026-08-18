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

    /// `ids` split into requests that are each within the cap for `kind`.
    ///
    /// Order is preserved and nothing is dropped: every caller of this reorders
    /// the merged result back to its own sequence, and a lookup that quietly
    /// discarded the tail would be the same bug one layer down.
    ///
    /// Empty in, empty out — an empty batch is a request for nothing, and
    /// sending it asks Apple Music a question with no answer.
    public static func batches<ID>(_ ids: [ID], for kind: ItemKind) -> [[ID]] {
        let size = maxIDs(for: kind)
        guard ids.count > size else { return ids.isEmpty ? [] : [ids] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }
}
