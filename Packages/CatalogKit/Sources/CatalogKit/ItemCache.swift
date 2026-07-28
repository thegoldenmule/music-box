import PolicyEngine

/// Somewhere to keep items we have already fetched.
///
/// A protocol rather than a concrete type because the storage question is not
/// settled: the MusicKit terms restrict what metadata we may persist and for
/// what purpose, so an on-disk cache needs an answer first. In-memory is the
/// safe starting point, and this is the seam that lets it change later without
/// touching anything that reads from it.
public protocol ItemCache: Sendable {
    func item(for id: CatalogID) async -> CatalogItem?
    func store(_ item: CatalogItem) async
    func store(_ items: [CatalogItem]) async
    func removeAll() async
}

extension ItemCache {
    public func store(_ items: [CatalogItem]) async {
        for item in items {
            await store(item)
        }
    }
}

/// Holds items for the life of the session and no longer.
///
/// Deliberately forgets everything on launch. That sidesteps the persistence
/// question entirely while still killing the repeat lookups that make a filtered
/// search page crawl.
public actor InMemoryItemCache: ItemCache {
    private var items: [CatalogID: CatalogItem] = [:]
    private let capacity: Int

    /// - Parameter capacity: how many items to keep before dropping the oldest
    ///   arrivals. A session's browsing is small; this is a backstop against a
    ///   long session growing without bound.
    public init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    public func item(for id: CatalogID) async -> CatalogItem? {
        items[id]
    }

    public func store(_ item: CatalogItem) async {
        if items.count >= capacity, items[item.id] == nil {
            items.removeAll(keepingCapacity: true)
        }
        items[item.id] = item
    }

    public func removeAll() async {
        items.removeAll()
    }

    public var count: Int {
        items.count
    }
}

/// Wraps any source so repeated lookups of the same item hit the cache.
///
/// Only `item(for:)` and `resolveAncestry(for:)` are cached — the two that
/// repeat. Searches are not: the same term can return different results as the
/// catalog changes, and a stale search page is worse than a slow one.
public struct CachingCatalogSource: CatalogSource {
    private let wrapped: any CatalogSource
    private let cache: any ItemCache

    public init(wrapping wrapped: any CatalogSource, cache: any ItemCache) {
        self.wrapped = wrapped
        self.cache = cache
    }

    public func search(
        term: String,
        kinds: Set<ItemKind>,
        limit: Int,
        offset: Int
    ) async throws -> CatalogPage {
        let page = try await wrapped.search(
            term: term, kinds: kinds, limit: limit, offset: offset
        )
        await cache.store(page.items)
        return page
    }

    public func item(for id: CatalogID) async throws -> CatalogItem? {
        if let cached = await cache.item(for: id) {
            return cached
        }
        guard let fetched = try await wrapped.item(for: id) else {
            return nil
        }
        await cache.store(fetched)
        return fetched
    }

    /// Serves what it can from the cache and asks for only the rest.
    ///
    /// Ordering follows the caller's, not the cache's: a recents screen is in
    /// time order, and splitting into hits and misses must not reshuffle it.
    public func items(for ids: [CatalogID]) async throws -> [CatalogItem] {
        var cached: [CatalogItem] = []
        var missing: [CatalogID] = []

        for id in ids {
            if let hit = await cache.item(for: id) {
                cached.append(hit)
            } else {
                missing.append(id)
            }
        }

        guard !missing.isEmpty else { return reorder(cached, like: ids) }

        let fetched = try await wrapped.items(for: missing)
        await cache.store(fetched)
        return reorder(cached + fetched, like: ids)
    }

    public func children(of id: CatalogID) async throws -> [CatalogItem] {
        let children = try await wrapped.children(of: id)
        await cache.store(children)
        return children
    }

    /// Not served from the cache, only stored into it: the cache is keyed by
    /// item, and nothing in it records *whose* credit an artist was.
    public func artists(of id: CatalogID) async throws -> [CatalogItem] {
        let artists = try await wrapped.artists(of: id)
        await cache.store(artists)
        return artists
    }

    public func resolveAncestry(for items: [CatalogItem]) async throws -> [CatalogItem] {
        var resolved: [CatalogItem] = []
        var needsFetch: [CatalogItem] = []

        for item in items {
            if !item.ancestors.isEmpty {
                resolved.append(item)
            } else if let cached = await cache.item(for: item.id),
                      !cached.ancestors.isEmpty {
                resolved.append(cached)
            } else {
                needsFetch.append(item)
            }
        }

        guard !needsFetch.isEmpty else {
            return reorder(resolved, like: items)
        }

        let fetched = try await wrapped.resolveAncestry(for: needsFetch)
        await cache.store(fetched)
        return reorder(resolved + fetched, like: items)
    }

    /// Keep the caller's ordering — search relevance is the ordering, and
    /// splitting into cached and uncached must not scramble it.
    private func reorder(_ items: [CatalogItem], like original: [CatalogItem]) -> [CatalogItem] {
        reorder(items, like: original.map(\.id))
    }

    private func reorder(_ items: [CatalogItem], like ids: [CatalogID]) -> [CatalogItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return ids.compactMap { byID[$0] }
    }
}
