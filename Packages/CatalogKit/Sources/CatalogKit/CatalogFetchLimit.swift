import PolicyEngine

/// Apple's per-lookup id cap, not search; one over-cap request fails whole.
public enum CatalogFetchLimit {
    /// The most identifiers of `kind` one request may carry.
    public static func maxIDs(for kind: ItemKind) -> Int {
        switch kind {
        case .song: 300
        case .album: 100
        case .artist, .playlist: 25
        }
    }

    /// Smaller than maxIDs(for:), so the first screenful returns sooner.
    public static let pageSize = 30

    /// Three: beats a serial queue, avoids the rate limit of asking for all.
    public static let inFlight = 3

    /// Order preserved, nothing dropped — a silent drop is a bug one layer down.
    public static func batches<ID>(_ ids: [ID], for kind: ItemKind) -> [[ID]] {
        batches(ids, of: maxIDs(for: kind))
    }

    /// Caller-chosen size, not Apple's cap; still divides by kind underneath.
    public static func batches<ID>(_ ids: [ID], of size: Int) -> [[ID]] {
        guard size > 0 else { return ids.isEmpty ? [] : [ids] }
        guard ids.count > size else { return ids.isEmpty ? [] : [ids] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }
}
