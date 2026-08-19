import PolicyEngine

/// An item the policy engine turned down, kept rather than dropped: blocks are the most useful
/// line in a parent's report, how they learn what their kid is curious about. The reports
/// screen turns these into one-tap "allow" buttons, so discarding them here costs the feature.
public struct BlockedItem: Sendable, Hashable {
    public let item: CatalogItem
    public let reason: Reason

    public init(item: CatalogItem, reason: Reason) {
        self.item = item
        self.reason = reason
    }
}

/// What a filtered search actually produced.
public struct FilteredResults: Sendable, Hashable {
    /// What the kid may see, capped at the requested limit.
    public let items: [CatalogItem]

    /// What was filtered out along the way, for the activity log.
    public let blocked: [BlockedItem]

    /// The source ran out of results. An empty page here genuinely means
    /// "nothing matches", and paging further is pointless.
    public let reachedEnd: Bool

    /// We hit the retry cap while still short of the limit. Distinct from
    /// ``reachedEnd``: this means we stopped looking, not that nothing is there.
    /// The UI should offer to keep going rather than claim an empty result.
    public let gaveUpEarly: Bool

    /// How many requests the source was asked for. Useful when tuning the
    /// over-fetch multiplier against real searches.
    public let requestCount: Int

    public init(
        items: [CatalogItem],
        blocked: [BlockedItem],
        reachedEnd: Bool,
        gaveUpEarly: Bool,
        requestCount: Int
    ) {
        self.items = items
        self.blocked = blocked
        self.reachedEnd = reachedEnd
        self.gaveUpEarly = gaveUpEarly
        self.requestCount = requestCount
    }
}

/// One search, kinds kept apart, for two reasons. Visible: results append songs then albums then
/// artists under one shared limit, so `prefix(limit)` cuts albums/artists off. Device-only:
/// Apple applies `limit`/`offset` per type, so a three-type request for 25 returns up to 75 —
/// read as one page it miscounts `hasMore` and skips catalog next time.
public struct KindedResults: Sendable, Hashable {
    /// Results for each kind whose loop has finished. Three states, not two: absent
    /// from both this and ``pending`` means never asked for; in ``pending`` means
    /// still on its way; here with no items means asked for and matched nothing.
    public let byKind: [ItemKind: FilteredResults]

    /// Kinds that were asked for and have not come back yet.
    ///
    /// Non-empty only on a snapshot from ``FilteredCatalog/searchIncrementally(term:budgets:)``.
    /// The awaited search never returns one of these.
    public let pending: Set<ItemKind>

    /// The order the kid's filter offers kinds in. Artists first: the kind a
    /// search is most often for, and cheapest — no rating means nothing filtered
    /// and no paging, so it's reliably first on screen. Songs before albums: a
    /// kid looking for a song outnumbers one looking for the record it came off.
    public static let displayOrder: [ItemKind] = [.artist, .song, .album, .playlist]

    public init(byKind: [ItemKind: FilteredResults], pending: Set<ItemKind> = []) {
        self.byKind = byKind
        self.pending = pending
    }

    public func results(for kind: ItemKind) -> FilteredResults? { byKind[kind] }

    public func items(of kind: ItemKind) -> [CatalogItem] { byKind[kind]?.items ?? [] }

    /// Whether this kind is still being fetched. Distinct from having come back
    /// empty, which is what makes a spinner and "nothing matched" different
    /// screens instead of the same guess.
    public func isPending(_ kind: ItemKind) -> Bool { pending.contains(kind) }

    /// Every kind has reported in.
    public var isComplete: Bool { pending.isEmpty }

    /// Which kinds actually returned something, in ``displayOrder``.
    public var populatedKinds: [ItemKind] {
        Self.displayOrder.filter { !items(of: $0).isEmpty }
    }

    /// Everything allowed, in ``displayOrder``. Order *within* a kind is the
    /// source's — search relevance is the ordering, and nothing reshuffles it.
    public var items: [CatalogItem] {
        Self.displayOrder.flatMap { items(of: $0) }
    }

    /// Every block from every kind, kept whole. The activity report is built
    /// from these, including results the kid never saw.
    public var blocked: [BlockedItem] {
        Self.displayOrder.flatMap { byKind[$0]?.blocked ?? [] }
    }

    /// Requests across every kind, so the number still means "what this search
    /// cost" now that a search is several loops.
    public var requestCount: Int {
        byKind.values.reduce(0) { $0 + $1.requestCount }
    }

    /// True when any kind stopped looking before it filled. Pessimistic and
    /// asymmetric with ``reachedEnd`` on purpose: "we stopped looking" must survive
    /// merging, since losing it turns a partial answer into a confident empty one.
    public var gaveUpEarly: Bool {
        byKind.values.contains { $0.gaveUpEarly }
    }

    /// True only when **every** kind ran out. Anything less and there is more to
    /// be had somewhere.
    public var reachedEnd: Bool {
        !byKind.isEmpty && byKind.values.allSatisfy(\.reachedEnd)
    }
}

/// A catalog source with a kid's policy applied to everything it returns. MusicKit
/// search takes a term, types, limit and offset, with no way to ask for clean results
/// only — filtering happens here after the fact, leaving holes in a page (ask for 25,
/// get 12). This compensates by over-asking and paging until the page is full.
public struct FilteredCatalog: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// How much more to ask for than we need. Wants measuring against real
        /// searches once we know how common explicit and unrated results are.
        public var overFetchMultiplier: Int

        /// Extra pages after the first before giving up, so a search with no
        /// clean results anywhere returns an honest empty state instead of
        /// spinning. One initial request plus this many retries.
        public var maxRetries: Int

        /// Upper bound on a single request. 25 is Apple Music's hard cap on search, not
        /// a preference — asking for more is a 400. Verified on device: the default used
        /// to be 100 and every search failed outright. Over-fetching past 25 happens by
        /// paging (``maxRetries``); ``overFetchMultiplier`` earns its keep below that.
        public var maxPageSize: Int

        public init(
            overFetchMultiplier: Int = 3,
            maxRetries: Int = 3,
            maxPageSize: Int = 25
        ) {
            self.overFetchMultiplier = overFetchMultiplier
            self.maxRetries = maxRetries
            self.maxPageSize = maxPageSize
        }

        public static let `default` = Configuration()
    }

    private let source: any CatalogSource
    private let engine: PolicyEngine
    private let configuration: Configuration

    public init(
        source: any CatalogSource,
        engine: PolicyEngine,
        configuration: Configuration = .default
    ) {
        self.source = source
        self.engine = engine
        self.configuration = configuration
    }

    /// Search, and return only what this kid may see.
    public func search(
        term: String,
        kinds: Set<ItemKind>,
        limit: Int
    ) async throws -> FilteredResults {
        guard limit > 0, !term.isEmpty, !kinds.isEmpty else {
            return FilteredResults(
                items: [], blocked: [], reachedEnd: true,
                gaveUpEarly: false, requestCount: 0
            )
        }

        let pageSize = min(limit * configuration.overFetchMultiplier, configuration.maxPageSize)

        var allowed: [CatalogItem] = []
        var blocked: [BlockedItem] = []
        /// Every identifier already judged this search, allowed or blocked. Paging
        /// can return an item from an earlier page: search order isn't stable across
        /// offsets, so an item can shift across a boundary and repeat. One set for
        /// both outcomes: the engine is pure, so a repeat gets the same verdict.
        var seen: Set<CatalogID> = []
        var offset = 0
        var requestCount = 0
        var retries = 0
        var reachedEnd = false

        while allowed.count < limit {
            let page = try await source.search(
                term: term, kinds: kinds, limit: pageSize, offset: offset
            )
            requestCount += 1
            offset += page.items.count

            // Lineage first — a song cannot be judged against a denied artist
            // without knowing who its artist is.
            let resolved = try await source.resolveAncestry(for: page.items)

            for item in resolved {
                // A duplicate is not merely a row shown twice. Every list above
                // this keys on the identifier — SwiftUI's `ForEach` does — and
                // two entries sharing one produce a blank the height of a row
                // where a song should be, with its separators missing too.
                guard seen.insert(item.id).inserted else { continue }

                switch engine.evaluate(item.policyItem) {
                case .allowed:
                    allowed.append(item)
                case .blocked(let reason):
                    blocked.append(BlockedItem(item: item, reason: reason))
                }
            }

            if page.items.isEmpty || !page.hasMore {
                reachedEnd = true
                break
            }
            if allowed.count >= limit {
                break
            }

            retries += 1
            if retries > configuration.maxRetries {
                break
            }
        }

        return FilteredResults(
            items: Array(allowed.prefix(limit)),
            blocked: blocked,
            reachedEnd: reachedEnd,
            gaveUpEarly: allowed.count < limit && !reachedEnd,
            requestCount: requestCount
        )
    }

    /// Search several kinds at once, each with its own budget: one over-fetch loop per
    /// kind, concurrently — see ``KindedResults`` for why merging is wrong twice over.
    /// Safe because the loops share nothing but the cache actor; any kind failing aborts
    /// the search, the existing retry rule. `budgets`: per-kind target, zero skips it.
    public func search(term: String, budgets: [ItemKind: Int]) async throws -> KindedResults {
        // Built on the incremental search rather than beside it, so the two
        // cannot drift. This one simply keeps the last snapshot.
        var latest = KindedResults(byKind: [:])
        for try await snapshot in searchIncrementally(term: term, budgets: budgets) {
            latest = snapshot
        }
        return latest
    }

    /// The same search, a kind at a time as each lands. Each element is a complete snapshot, not a delta — a caller replaces
    /// state, never accumulates. Kinds don't cost the same: artists settle in one request, songs page repeatedly, so
    /// awaiting all three blocks the fast on the slow. Dropping the stream cancels searches, since a kid retypes.
    public func searchIncrementally(
        term: String,
        budgets: [ItemKind: Int]
    ) -> AsyncThrowingStream<KindedResults, any Error> {
        let wanted = budgets.filter { $0.value > 0 }
        guard !term.isEmpty, !wanted.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }

        // Started in display order so the kind the screen opens on has its
        // request away first. It is a head start, not a guarantee — the group
        // still yields in completion order.
        let ordered = wanted.keys.sorted { a, b in
            let order = KindedResults.displayOrder
            return (order.firstIndex(of: a) ?? .max) < (order.firstIndex(of: b) ?? .max)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var byKind: [ItemKind: FilteredResults] = [:]
                var pending = Set(wanted.keys)
                continuation.yield(KindedResults(byKind: byKind, pending: pending))

                do {
                    try await withThrowingTaskGroup(of: (ItemKind, FilteredResults).self) { group in
                        for kind in ordered {
                            guard let limit = wanted[kind] else { continue }
                            group.addTask {
                                (kind, try await self.search(term: term, kinds: [kind], limit: limit))
                            }
                        }
                        for try await (kind, results) in group {
                            byKind[kind] = results
                            pending.remove(kind)
                            continuation.yield(KindedResults(byKind: byKind, pending: pending))
                        }
                    }
                    continuation.finish()
                } catch {
                    // One kind failing aborts the search, which is the existing
                    // rule: the loop retries to fill a page, never to recover
                    // from a failure.
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What is inside a container, filtered.
    ///
    /// Used for browsing an album or artist, and for playing a playlist — the
    /// blocked entries are what the player skips rather than stopping on.
    public func children(of id: CatalogID) async throws -> FilteredResults {
        try await judge(source.children(of: id))
    }

    /// An artist's top songs, filtered — the same treatment albums get, and for the
    /// same reason: this is a list a kid is handed, so a denied track is absent
    /// rather than shown and refused. The blocked half comes back for the report.
    public func topSongs(of id: CatalogID) async throws -> FilteredResults {
        try await judge(source.topSongs(of: id))
    }

    /// Resolve lineage for a list, then run the whole of it past the engine. Ancestry
    /// first — a song can't be judged against a denied artist without knowing who its
    /// artist is, and on a page that is an artist that isn't hypothetical.
    private func judge(_ items: [CatalogItem]) async throws -> FilteredResults {
        let resolved = try await source.resolveAncestry(for: items)

        var allowed: [CatalogItem] = []
        var blocked: [BlockedItem] = []
        for item in resolved {
            switch engine.evaluate(item.policyItem) {
            case .allowed:
                allowed.append(item)
            case .blocked(let reason):
                blocked.append(BlockedItem(item: item, reason: reason))
            }
        }

        return FilteredResults(
            items: allowed,
            blocked: blocked,
            reachedEnd: true,
            gaveUpEarly: false,
            requestCount: 1
        )
    }

    /// The credited artists this kid may actually visit: filtered because a credit links to that artist's catalogue.
    /// Dropped, not returned blocked — nothing was rendered, so there's nothing to report; the album already logs.
    /// Matters because a record stays reachable while a co-credit is denied, since ancestry only carries the first.
    public func artists(of id: CatalogID) async throws -> [CatalogItem] {
        try await source.artists(of: id).filter { engine.evaluate($0.policyItem).isAllowed }
    }

    /// Judge one item, resolving its lineage first if it has none.
    ///
    /// This is what the player calls immediately before playback starts. It asks
    /// again rather than trusting that the UI only offered allowed things.
    public func verdict(for item: CatalogItem) async throws -> Verdict {
        let resolved = item.ancestors.isEmpty
            ? (try await source.resolveAncestry(for: [item])).first ?? item
            : item
        return engine.evaluate(resolved.policyItem)
    }
}
