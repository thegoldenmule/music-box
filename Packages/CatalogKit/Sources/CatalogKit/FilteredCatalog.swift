import PolicyEngine

/// An item the policy engine turned down, kept rather than dropped.
///
/// Blocks are the most useful line in a parent's report — they are how a parent
/// finds out their kid is curious about something. The reports screen turns
/// these into one-tap "allow this" buttons, so throwing them away here would
/// cost the feature.
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

    /// We hit the retry cap while still short of the limit.
    ///
    /// The distinction from ``reachedEnd`` matters: this means "we stopped
    /// looking", not "there is nothing there". The UI should offer to keep
    /// going rather than claiming an empty result.
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

/// One search, with each kind's results kept apart.
///
/// Apart rather than merged, for two reasons that are easy to conflate.
///
/// The visible one: the adapter appends songs before albums before artists, and
/// ``FilteredResults`` caps at a single limit. One shared budget therefore means
/// `prefix(limit)` cuts every album and artist off the end of a full page of
/// songs — a caller asking for all three kinds gets songs and nothing else, and
/// it looks like the catalog simply had no albums to offer.
///
/// The one that would only have shown up on device: the over-fetch loop's paging
/// arithmetic assumes a page belongs to a single kind. Apple Music applies
/// `limit` and `offset` **per type**, so a three-type request for 25 comes back
/// with up to 75 items. `hasMore` reads that as one full page when it is really
/// three, and `offset += page.items.count` then advances three times further
/// than any single type moved — skipping most of the catalogue on the second
/// request. Running one loop per kind keeps every one of those assumptions true
/// rather than patching around them.
public struct KindedResults: Sendable, Hashable {
    /// Results for each kind that was asked for.
    ///
    /// A kind that was never requested is absent. A kind that was requested and
    /// matched nothing is present and empty — the caller needs to tell those
    /// apart to know whether a filter is worth offering.
    public let byKind: [ItemKind: FilteredResults]

    /// Containers first, then songs.
    ///
    /// An artist or an album is a way *further in*: tapping one pushes a browse
    /// screen, which is how a kid reaches a whole record rather than the single
    /// track that happened to match their spelling. Songs are the long tail, and
    /// a page of them above the artist buries the thing most searches are
    /// actually for.
    public static let displayOrder: [ItemKind] = [.artist, .album, .song, .playlist]

    public init(byKind: [ItemKind: FilteredResults]) {
        self.byKind = byKind
    }

    public func results(for kind: ItemKind) -> FilteredResults? { byKind[kind] }

    public func items(of kind: ItemKind) -> [CatalogItem] { byKind[kind]?.items ?? [] }

    /// Which kinds actually returned something, in ``displayOrder``. What a
    /// filter control should offer: a filter leading to an empty screen is a
    /// dead end a kid has no way to interpret.
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

    /// True when **any** kind stopped looking before it filled.
    ///
    /// Pessimistic on purpose, and asymmetric with ``reachedEnd`` on purpose:
    /// "we stopped looking" is the claim that must survive being merged, since
    /// losing it turns a partial answer into a confident empty one.
    public var gaveUpEarly: Bool {
        byKind.values.contains { $0.gaveUpEarly }
    }

    /// True only when **every** kind ran out. Anything less and there is more to
    /// be had somewhere.
    public var reachedEnd: Bool {
        !byKind.isEmpty && byKind.values.allSatisfy(\.reachedEnd)
    }
}

/// A catalog source with a kid's policy applied to everything that comes out of
/// it.
///
/// MusicKit search takes a term, types, a limit and an offset, and offers no way
/// to ask for clean results only. So filtering happens here, after the fact,
/// which leaves holes in a page — ask for 25 and get 12. This compensates by
/// asking for more than it needs and paging until the page is full.
public struct FilteredCatalog: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// How much more to ask for than we need. Wants measuring against real
        /// searches once we know how common explicit and unrated results are.
        public var overFetchMultiplier: Int

        /// Extra pages after the first before giving up, so a search with no
        /// clean results anywhere returns an honest empty state instead of
        /// spinning. One initial request plus this many retries.
        public var maxRetries: Int

        /// Upper bound on a single request.
        ///
        /// **25 is Apple Music's hard cap on search, not a preference.** Asking
        /// for more is a 400: `40005 Invalid Parameter Value — Value must be an
        /// integer less than or equal to 25`. Verified on device; the default
        /// used to be 100 and every search with a limit of 25 failed outright.
        ///
        /// The consequence is that over-fetching cannot happen by asking for a
        /// bigger page once the limit reaches 25 — it happens by paging, which
        /// is what ``maxRetries`` is for. ``overFetchMultiplier`` still earns
        /// its keep at smaller limits, where one request can cover the need.
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

    /// Search several kinds at once, each with its own budget.
    ///
    /// One over-fetch loop per kind, run concurrently, rather than one loop over
    /// a mixed request — see ``KindedResults`` for why merging them is wrong in
    /// two separate ways.
    ///
    /// Concurrent because three searches in series is three times the wait on a
    /// screen someone is staring at. It is safe because the loops share nothing:
    /// each owns its offset, its retry count and its accumulators, and the only
    /// thing they touch in common is the cache, which is an actor. An error in
    /// any one of them aborts the whole search, which is the existing rule —
    /// the loop retries to fill a page, never to recover from a failure.
    ///
    /// - Parameter budgets: how many allowed items to aim for, per kind. A kind
    ///   mapped to zero or less is skipped entirely and makes no request.
    public func search(term: String, budgets: [ItemKind: Int]) async throws -> KindedResults {
        let wanted = budgets.filter { $0.value > 0 }
        guard !term.isEmpty, !wanted.isEmpty else { return KindedResults(byKind: [:]) }

        return try await withThrowingTaskGroup(of: (ItemKind, FilteredResults).self) { group in
            for (kind, limit) in wanted {
                group.addTask {
                    (kind, try await self.search(term: term, kinds: [kind], limit: limit))
                }
            }

            var byKind: [ItemKind: FilteredResults] = [:]
            for try await (kind, results) in group {
                byKind[kind] = results
            }
            // Completion order is a race; the dictionary is not, and everything
            // downstream reads it through `KindedResults.displayOrder`.
            return KindedResults(byKind: byKind)
        }
    }

    /// What is inside a container, filtered.
    ///
    /// Used for browsing an album or artist, and for playing a playlist — the
    /// blocked entries are what the player skips rather than stopping on.
    public func children(of id: CatalogID) async throws -> FilteredResults {
        let children = try await source.children(of: id)
        let resolved = try await source.resolveAncestry(for: children)

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
