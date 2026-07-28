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
    /// Results for each kind whose loop has finished.
    ///
    /// Three states, not two, and they are worth keeping apart: a kind absent
    /// from both this and ``pending`` was never asked for; a kind in ``pending``
    /// is still on its way; a kind here with no items was asked for and matched
    /// nothing.
    public let byKind: [ItemKind: FilteredResults]

    /// Kinds that were asked for and have not come back yet.
    ///
    /// Non-empty only on a snapshot from ``FilteredCatalog/searchIncrementally(term:budgets:)``.
    /// The awaited search never returns one of these.
    public let pending: Set<ItemKind>

    /// The order the kid's filter offers them in.
    ///
    /// Artists first because it is the kind a search is most often *for* — and,
    /// usefully, the cheapest to fetch: artists carry no rating so nothing is
    /// filtered out, which means one request and no paging. It is reliably the
    /// first kind on screen.
    ///
    /// Songs before albums because a kid looking for a particular song is the
    /// commoner case than one looking for the record it came off.
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
        /// Every identifier already judged on this search, allowed or blocked.
        ///
        /// Paging can hand back an item that came on an earlier page. Search
        /// ordering is Apple's relevance ranking and nothing promises it is
        /// stable between two requests at different offsets, so an item can
        /// shift across a page boundary and be returned twice.
        ///
        /// One set covering both outcomes, not one per outcome: the engine is
        /// pure, so the same item judged twice gets the same verdict, and a
        /// repeat is a repeat whichever list it landed in.
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
        // Built on the incremental search rather than beside it, so the two
        // cannot drift. This one simply keeps the last snapshot.
        var latest = KindedResults(byKind: [:])
        for try await snapshot in searchIncrementally(term: term, budgets: budgets) {
            latest = snapshot
        }
        return latest
    }

    /// The same search, delivered a kind at a time as each one lands.
    ///
    /// Every element is a **complete snapshot**, not a delta: the kinds that
    /// have arrived so far, plus ``KindedResults/pending`` naming the ones still
    /// out. A caller replaces its state with each element and never accumulates.
    ///
    /// This exists because the kinds do not cost the same. Artists carry no
    /// rating, so nothing is filtered out of that page and it settles in a
    /// single request; songs lose results to the rating check and page two,
    /// three or four times to fill their budget. Awaiting all three means the
    /// screen waits on the slowest, showing nothing, when the kind it opens on
    /// has been ready most of that time.
    ///
    /// The first element is always the empty snapshot with everything pending,
    /// so a caller knows which kinds are coming before any of them arrive.
    ///
    /// Cancellation propagates: dropping the stream cancels the searches behind
    /// it, which matters because a kid types a second term over the first.
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

    /// An artist's top songs, filtered.
    ///
    /// The same treatment their albums get, and for the same reason: this is a
    /// list a kid is handed, so a denied track is absent from it rather than
    /// shown and refused. The blocked half comes back for the report.
    public func topSongs(of id: CatalogID) async throws -> FilteredResults {
        try await judge(source.topSongs(of: id))
    }

    /// Resolve lineage for a list, then run the whole of it past the engine.
    ///
    /// Ancestry first — a song cannot be judged against a denied artist without
    /// knowing who its artist is, and on a page that *is* an artist that is not a
    /// hypothetical.
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

    /// The credited artists this kid may actually visit.
    ///
    /// Filtered like anything else, because a credit on an album page is a link
    /// to that artist's whole catalogue — in level 1 an artist who is not on the
    /// allow list opens onto nothing, and in level 2 a denied one is precisely
    /// what a deny is for. What is left is dropped rather than returned blocked:
    /// nothing was rendered and nothing was reached for, so there is no block to
    /// report. The album the kid did open is the event worth logging, and its
    /// caller already does.
    ///
    /// A co-credit disappearing is why this is worth doing at all: a record can
    /// be reachable while one of its two artists is denied, since ancestry only
    /// ever carried the first of them.
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
