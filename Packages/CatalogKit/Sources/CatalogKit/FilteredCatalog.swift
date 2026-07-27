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

        /// Upper bound on a single request, so a large limit times the
        /// multiplier cannot ask MusicKit for something absurd.
        public var maxPageSize: Int

        public init(
            overFetchMultiplier: Int = 3,
            maxRetries: Int = 3,
            maxPageSize: Int = 100
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
