import PolicyEngine

/// A protocol, not concrete: MusicKit's persistence terms are still unsettled.
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

/// Session-only, forgotten on launch — sidesteps persistence, cuts repeat lookups.
public actor InMemoryItemCache: ItemCache {
    private var items: [CatalogID: CatalogItem] = [:]
    private let capacity: Int

    /// - Parameter capacity: backstop against an unbounded session, not a limit.
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

/// Caches item(for:), resolveAncestry(for:) only — slow beats a stale search.
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

    /// Cache hits plus a fetch for the rest; caller's order survives the split.
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

    public func topSongs(of id: CatalogID) async throws -> [CatalogItem] {
        let songs = try await wrapped.topSongs(of: id)
        await cache.store(songs)
        return songs
    }

    /// Stored, not served — keyed by item, not by whose credit it was.
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

    /// Keeps caller order — splitting cached from uncached must not scramble it.
    private func reorder(_ items: [CatalogItem], like original: [CatalogItem]) -> [CatalogItem] {
        reorder(items, like: original.map(\.id))
    }

    private func reorder(_ items: [CatalogItem], like ids: [CatalogID]) -> [CatalogItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return ids.compactMap { byID[$0] }
    }
}
