import PolicyEngine

/// Kept, not dropped: parent reports turn blocks into one-tap allow buttons.
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

    /// Source exhausted: an empty page means no matches, not merely a pause.
    public let reachedEnd: Bool

    /// Hit retry cap below limit; unlike reachedEnd, offer more, not empty.
    public let gaveUpEarly: Bool

    /// Requests made, for tuning ``overFetchMultiplier`` against real searches.
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

/// Kinds separate: Apple pages limit/offset per type, breaking hasMore if merged.
public struct KindedResults: Sendable, Hashable {
    /// Per kind: absent = never asked, `pending` = in flight, empty = no match.
    public let byKind: [ItemKind: FilteredResults]

    /// Kinds still in flight; empty once the search (not a snapshot) returns.
    public let pending: Set<ItemKind>

    /// Order: artists first (cheap, unrated), songs before albums by frequency.
    public static let displayOrder: [ItemKind] = [.artist, .song, .album, .playlist]

    public init(byKind: [ItemKind: FilteredResults], pending: Set<ItemKind> = []) {
        self.byKind = byKind
        self.pending = pending
    }

    public func results(for kind: ItemKind) -> FilteredResults? { byKind[kind] }

    public func items(of kind: ItemKind) -> [CatalogItem] { byKind[kind]?.items ?? [] }

    /// Distinct from empty: keeps a spinner from reading as "no matches".
    public func isPending(_ kind: ItemKind) -> Bool { pending.contains(kind) }

    /// Every kind has reported in.
    public var isComplete: Bool { pending.isEmpty }

    /// Which kinds actually returned something, in ``displayOrder``.
    public var populatedKinds: [ItemKind] {
        Self.displayOrder.filter { !items(of: $0).isEmpty }
    }

    /// Allowed items in ``displayOrder``; within a kind, source order stands.
    public var items: [CatalogItem] {
        Self.displayOrder.flatMap { items(of: $0) }
    }

    /// Every block, kept whole — the activity report includes results never shown.
    public var blocked: [BlockedItem] {
        Self.displayOrder.flatMap { byKind[$0]?.blocked ?? [] }
    }

    /// Summed across kinds, so it still means "what this search cost".
    public var requestCount: Int {
        byKind.values.reduce(0) { $0 + $1.requestCount }
    }

    /// True if any kind gave up; must survive merging or a partial reads as empty.
    public var gaveUpEarly: Bool {
        byKind.values.contains { $0.gaveUpEarly }
    }

    /// True only once every kind has run out — otherwise more exists somewhere.
    public var reachedEnd: Bool {
        !byKind.isEmpty && byKind.values.allSatisfy(\.reachedEnd)
    }
}

/// MusicKit can't filter server-side; this over-fetches and pages to fill holes.
public struct FilteredCatalog: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Over-fetch factor; unmeasured pending explicit/unrated frequency data.
        public var overFetchMultiplier: Int

        /// Retries past first page so a truly empty search ends, not spins.
        public var maxRetries: Int

        /// 25 is Apple's search cap — over 25 was a device-verified 400.
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
        /// Judged ids so far — paging can repeat one if the source's order shifts.
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

            // Lineage first: can't judge a song against a denied artist blind.
            let resolved = try await source.resolveAncestry(for: page.items)

            for item in resolved {
                // Duplicate ids break `ForEach`: a blank row, separators gone.
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

    /// One loop per kind, concurrently; any kind failing aborts the search.
    public func search(term: String, budgets: [ItemKind: Int]) async throws -> KindedResults {
        // Built atop incremental search, not beside it, so they can't drift.
        var latest = KindedResults(byKind: [:])
        for try await snapshot in searchIncrementally(term: term, budgets: budgets) {
            latest = snapshot
        }
        return latest
    }

    /// Snapshot stream; dropping it cancels searches when a kid retypes.
    public func searchIncrementally(
        term: String,
        budgets: [ItemKind: Int]
    ) -> AsyncThrowingStream<KindedResults, any Error> {
        let wanted = budgets.filter { $0.value > 0 }
        guard !term.isEmpty, !wanted.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }

        // Display order first for a head start; group still yields by completion.
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
                    // One kind failing aborts the search; retries only fill pages.
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Container contents, filtered; playlist skips blocked, doesn't stop.
    public func children(of id: CatalogID) async throws -> FilteredResults {
        try await judge(source.children(of: id))
    }

    /// Top songs, filtered like albums: a denied track is absent, not refused.
    public func topSongs(of id: CatalogID) async throws -> FilteredResults {
        try await judge(source.topSongs(of: id))
    }

    /// Resolves ancestry first — can't judge against a denied artist blind.
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

    /// Dropped, not blocked: unrendered, unreported; co-credit stays reachable.
    public func artists(of id: CatalogID) async throws -> [CatalogItem] {
        try await source.artists(of: id).filter { engine.evaluate($0.policyItem).isAllowed }
    }

    /// Called right before playback; re-asks rather than trusting the UI's offer.
    public func verdict(for item: CatalogItem) async throws -> Verdict {
        let resolved = item.ancestors.isEmpty
            ? (try await source.resolveAncestry(for: [item])).first ?? item
            : item
        return engine.evaluate(resolved.policyItem)
    }
}
