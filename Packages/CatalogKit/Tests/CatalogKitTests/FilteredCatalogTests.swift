import Testing

import CatalogKit
import PolicyEngine

@Suite("Filtering")
struct FilteringTests {
    @Test("Explicit results are dropped and clean ones kept")
    func dropsExplicit() async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(10, hasMore: false)])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", kinds: [.song], limit: 10)

        #expect(results.items.count == 5)
        #expect(results.items.allSatisfy { $0.rating == .clean })
    }

    @Test("Blocked items are kept with their reason, for the report")
    func keepsBlocked() async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(10, hasMore: false)])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", kinds: [.song], limit: 10)

        #expect(results.blocked.count == 5)
        #expect(results.blocked.allSatisfy { $0.reason == .explicitContent })
    }

    @Test("Results are capped at the requested limit")
    func capsAtLimit() async throws {
        let clean = (0..<30).map { Fix.songItem($0, rating: .clean) }
        let source = StubCatalogSource(pages: [Fix.page(clean, hasMore: false)])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", kinds: [.song], limit: 5)

        #expect(results.items.count == 5)
    }

    @Test("A deny on the artist blocks the song, once ancestry is resolved")
    func ancestryIsResolvedBeforeJudging() async throws {
        let source = StubCatalogSource(
            pages: [Fix.page([Fix.songItem(0, rating: .clean)], hasMore: false)],
            ancestry: [Fix.song(0): [Ancestor(id: Fix.album), Ancestor(id: Fix.artist)]]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine(.denyPlusAuto, [.deny(Fix.artist)]))

        let results = try await sut.search(term: "x", kinds: [.song], limit: 10)

        #expect(results.items.isEmpty)
        #expect(results.blocked.first?.reason == .deniedByParent(Fix.artist))
    }

    @Test("Ancestry is resolved once per page, not once per item")
    func ancestryIsBatched() async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(20, hasMore: false)])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        _ = try await sut.search(term: "x", kinds: [.song], limit: 10)

        #expect(await source.ancestryCallCount == 1)
        #expect(await source.ancestryResolvedCount == 20)
    }
}

@Suite("Over-fetch loop")
struct OverFetchTests {
    @Test("Asks for more than the limit, to leave room for filtering")
    func overFetches() async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(30, hasMore: false)])
        let config = FilteredCatalog.Configuration(overFetchMultiplier: 3)
        let sut = FilteredCatalog(source: source, engine: Fix.engine(), configuration: config)

        // Five, not the old twenty-five: the multiplier only has room to work
        // below Apple Music's cap of 25 per search request.
        _ = try await sut.search(term: "x", kinds: [.song], limit: 5)

        #expect(await source.searchCalls.first?.limit == 15)
    }

    @Test(
        "No search ever asks Apple Music for more than it allows",
        arguments: [1, 5, 10, 25, 50, 100]
    )
    func neverExceedsAppleMusicsCap(limit: Int) async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(30, hasMore: false)])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        _ = try await sut.search(term: "x", kinds: [.song], limit: limit)

        // Asking for 75 is a 400 from Apple Music, not a large page. Every
        // search failed outright until the default page ceiling came down to
        // 25, and nothing in the package caught it — the stub happily served
        // whatever it was asked for.
        let asked = await source.searchCalls.map(\.limit)
        #expect(asked.allSatisfy { $0 <= 25 })
        #expect(!asked.isEmpty)
    }

    @Test("A single request never exceeds the page ceiling")
    func respectsPageCeiling() async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(10, hasMore: false)])
        // A ceiling below the API's own cap, so this exercises the ceiling
        // rather than implying a page of 50 is something Apple Music would
        // serve. It would not — see `Configuration.maxPageSize`.
        let config = FilteredCatalog.Configuration(overFetchMultiplier: 10, maxPageSize: 20)
        let sut = FilteredCatalog(source: source, engine: Fix.engine(), configuration: config)

        _ = try await sut.search(term: "x", kinds: [.song], limit: 25)

        #expect(await source.searchCalls.first?.limit == 20)
    }

    @Test("Pages again when the first page came up short")
    func pagesUntilFull() async throws {
        // Two clean per page, needs 5 — so three pages.
        let source = StubCatalogSource(
            pages: [
                Fix.mixedPage(4, startingAt: 0),
                Fix.mixedPage(4, startingAt: 4),
                Fix.mixedPage(4, startingAt: 8),
            ]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", kinds: [.song], limit: 5)

        #expect(results.items.count == 5)
        #expect(results.requestCount == 3)
    }

    @Test("Offset advances by what the source actually returned")
    func offsetAdvances() async throws {
        let source = StubCatalogSource(
            pages: [Fix.mixedPage(4, startingAt: 0), Fix.mixedPage(4, startingAt: 4, hasMore: false)]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        _ = try await sut.search(term: "x", kinds: [.song], limit: 10)

        let offsets = await source.searchCalls.map(\.offset)
        #expect(offsets == [0, 4])
    }

    @Test("Gives up after the retry cap rather than spinning")
    func stopsAtRetryCap() async throws {
        // Every page is entirely explicit and always claims more.
        let explicitPages = (0..<20).map { page in
            Fix.page(
                (0..<4).map { Fix.songItem(page * 4 + $0, rating: .explicit) },
                hasMore: true
            )
        }
        let source = StubCatalogSource(pages: explicitPages)
        let config = FilteredCatalog.Configuration(maxRetries: 3)
        let sut = FilteredCatalog(source: source, engine: Fix.engine(), configuration: config)

        let results = try await sut.search(term: "x", kinds: [.song], limit: 10)

        // One initial request plus three retries.
        #expect(results.requestCount == 4)
        #expect(results.items.isEmpty)
        #expect(results.gaveUpEarly)
        #expect(!results.reachedEnd)
    }

    @Test("Running out of results is reported as the end, not as giving up")
    func reachedEndIsNotGivingUp() async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(4, hasMore: false)])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", kinds: [.song], limit: 10)

        #expect(results.reachedEnd)
        #expect(!results.gaveUpEarly)
        #expect(results.requestCount == 1)
    }

    @Test("An empty page ends the loop")
    func emptyPageEnds() async throws {
        let source = StubCatalogSource(pages: [Fix.page([], hasMore: true)])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", kinds: [.song], limit: 10)

        #expect(results.items.isEmpty)
        #expect(results.reachedEnd)
        #expect(results.requestCount == 1)
    }

    @Test("Degenerate inputs make no requests at all", arguments: [
        (term: "", limit: 10, kinds: Set<ItemKind>([.song])),
        (term: "x", limit: 0, kinds: Set<ItemKind>([.song])),
        (term: "x", limit: 10, kinds: Set<ItemKind>()),
    ])
    func degenerateInputs(input: (term: String, limit: Int, kinds: Set<ItemKind>)) async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(10)])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: input.term, kinds: input.kinds, limit: input.limit)

        #expect(results.items.isEmpty)
        #expect(await source.searchCalls.isEmpty)
    }
}

@Suite("Kinded search")
struct KindedSearchTests {
    /// Three kinds, and enough songs to swamp the other two if they shared a
    /// budget.
    private func source() -> StubCatalogSource {
        StubCatalogSource(pagesByKind: [
            .artist: [Fix.page((0..<3).map(Fix.artistItem), hasMore: false)],
            .album: [Fix.page((0..<4).map { Fix.albumItem($0) }, hasMore: false)],
            .song: [Fix.page((0..<30).map { Fix.songItem($0) }, hasMore: false)],
        ])
    }

    @Test("Every kind comes back — songs do not crowd out albums and artists")
    func everyKindSurvives() async throws {
        let sut = FilteredCatalog(source: source(), engine: Fix.engine())

        let results = try await sut.search(term: "x", budgets: [.artist: 6, .album: 6, .song: 24])

        // The bug this exists to catch: one shared limit, plus the adapter
        // appending songs first, means `prefix(limit)` cuts every album and
        // artist off the end of a full page of songs. The screen then looks
        // exactly as if the catalog had no albums to offer.
        #expect(results.items(of: .artist).count == 3)
        #expect(results.items(of: .album).count == 4)
        #expect(results.items(of: .song).count == 24)
    }

    @Test("Each kind is asked for on its own, never in one mixed request")
    func neverMixesKindsInARequest() async throws {
        let source = source()
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        _ = try await sut.search(term: "x", budgets: [.artist: 6, .album: 6, .song: 24])

        // The whole reason this is one loop per kind. Apple Music applies
        // `limit` and `offset` per type, so a mixed request breaks both the
        // `hasMore` inference and the offset arithmetic — silently, and only
        // on device.
        let calls = await source.searchCalls
        #expect(calls.allSatisfy { $0.kinds.count == 1 })
        #expect(await source.searchCallCount(for: .artist) == 1)
        #expect(await source.searchCallCount(for: .album) == 1)
        #expect(await source.searchCallCount(for: .song) == 1)
    }

    @Test("Each kind gets its own budget, not a share of one")
    func budgetsArePerKind() async throws {
        let source = source()
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        _ = try await sut.search(term: "x", budgets: [.artist: 2, .song: 24])

        // Over-fetch is per kind too: 2 × 3 for artists, and songs clamped at
        // Apple Music's cap of 25.
        let asked = await source.searchCalls
        #expect(asked.first { $0.kinds == [.artist] }?.limit == 6)
        #expect(asked.first { $0.kinds == [.song] }?.limit == 25)
    }

    @Test("A kind with no budget makes no request at all")
    func zeroBudgetIsSkipped() async throws {
        let source = source()
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", budgets: [.song: 10, .album: 0])

        #expect(await source.searchCallCount(for: .album) == 0)
        // Absent, not present-and-empty: never asked for is a different fact
        // from asked for and found nothing, and a filter control needs both.
        #expect(results.results(for: .album) == nil)
        #expect(results.results(for: .song) != nil)
    }

    @Test("Artists survive UnratedBehavior.block, which would otherwise hide them all")
    func artistsAreNotBlockedAsUnrated() async throws {
        // Artists carry no rating in the catalog, so `nil` here is normal
        // rather than missing data. The engine treats them as containers for
        // exactly this reason — without that, turning on artist search under
        // the default unrated behavior would return nothing, every time.
        let sut = FilteredCatalog(source: source(), engine: Fix.engine(unrated: .block))

        let results = try await sut.search(term: "x", budgets: [.artist: 6])

        #expect(results.items(of: .artist).count == 3)
        #expect(results.blocked.isEmpty)
    }

    @Test("An album result is still judged against a deny on its artist")
    func ancestryIsResolvedForAlbumsToo() async throws {
        let source = StubCatalogSource(
            pagesByKind: [.album: [Fix.page([Fix.albumItem(0)], hasMore: false)]],
            ancestry: [CatalogID(.album, "album-0"): [Ancestor(id: Fix.artist)]]
        )
        let sut = FilteredCatalog(
            source: source,
            engine: Fix.engine(.denyPlusAuto, [.deny(Fix.artist)])
        )

        let results = try await sut.search(term: "x", budgets: [.album: 6])

        #expect(results.items.isEmpty)
        #expect(results.blocked.first?.reason == .deniedByParent(Fix.artist))
    }

    @Test("Allowed items follow the order the kid's filter offers them in")
    func followsDisplayOrder() async throws {
        let sut = FilteredCatalog(source: source(), engine: Fix.engine())

        let results = try await sut.search(term: "x", budgets: [.artist: 6, .album: 6, .song: 24])

        // Artists, then songs, then albums — the tab order, so the two cannot
        // disagree about what "first" means.
        #expect(results.items.prefix(3).allSatisfy { $0.id.kind == .artist })
        #expect(results.items.dropFirst(3).prefix(24).allSatisfy { $0.id.kind == .song })
        #expect(results.items.dropFirst(27).allSatisfy { $0.id.kind == .album })
    }

    @Test("Only kinds that found something are offered as filters")
    func populatedKindsSkipsEmptyOnes() async throws {
        let source = StubCatalogSource(pagesByKind: [
            .artist: [Fix.page((0..<2).map(Fix.artistItem), hasMore: false)],
            .album: [Fix.page([], hasMore: false)],
            .song: [Fix.page((0..<5).map { Fix.songItem($0) }, hasMore: false)],
        ])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", budgets: [.artist: 6, .album: 6, .song: 24])

        // A filter that leads to an empty screen is a dead end a kid has no way
        // to interpret, so the control is built from this rather than from what
        // was asked for.
        #expect(results.populatedKinds == [.artist, .song])
    }

    @Test("One kind giving up is reported, and does not read as the end")
    func gaveUpEarlyWinsOverReachedEnd() async throws {
        // Songs are entirely explicit and the source always claims more, so
        // that loop burns its retries; artists run out honestly on page one.
        let explicit = (0..<20).map { page in
            Fix.page((0..<4).map { Fix.songItem(page * 4 + $0, rating: .explicit) }, hasMore: true)
        }
        let source = StubCatalogSource(pagesByKind: [
            .song: explicit,
            .artist: [Fix.page([Fix.artistItem(0)], hasMore: false)],
        ])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", budgets: [.song: 10, .artist: 6])

        // Asymmetric on purpose: "we stopped looking" has to survive the merge,
        // because losing it turns a partial answer into a confident empty one.
        #expect(results.gaveUpEarly)
        #expect(!results.reachedEnd)
        #expect(results.results(for: .artist)?.reachedEnd == true)
        // Four requests for songs, one for artists.
        #expect(results.requestCount == 5)
    }

    @Test("Degenerate inputs make no requests at all", arguments: [
        (term: "", budgets: [ItemKind.song: 10]),
        (term: "x", budgets: [ItemKind: Int]()),
        (term: "x", budgets: [ItemKind.song: 0]),
    ])
    func degenerateInputs(input: (term: String, budgets: [ItemKind: Int])) async throws {
        let source = source()
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: input.term, budgets: input.budgets)

        #expect(results.items.isEmpty)
        #expect(await source.searchCalls.isEmpty)
    }
}

@Suite("Incremental search")
struct IncrementalSearchTests {
    private func source() -> StubCatalogSource {
        StubCatalogSource(pagesByKind: [
            .artist: [Fix.page((0..<3).map(Fix.artistItem), hasMore: false)],
            .album: [Fix.page((0..<4).map { Fix.albumItem($0) }, hasMore: false)],
            .song: [Fix.page((0..<30).map { Fix.songItem($0) }, hasMore: false)],
        ])
    }

    private func snapshots(
        _ sut: FilteredCatalog,
        budgets: [ItemKind: Int] = [.artist: 6, .album: 6, .song: 24]
    ) async throws -> [KindedResults] {
        var all: [KindedResults] = []
        for try await snapshot in sut.searchIncrementally(term: "x", budgets: budgets) {
            all.append(snapshot)
        }
        return all
    }

    @Test("An opening snapshot names what is coming before any of it arrives")
    func opensWithEverythingPending() async throws {
        let sut = FilteredCatalog(source: source(), engine: Fix.engine())

        let all = try await snapshots(sut)

        // The empty opener, then one snapshot per kind as it lands.
        #expect(all.count == 4)
        #expect(all.first?.byKind.isEmpty == true)
        #expect(all.first?.pending == [.artist, .album, .song])
        #expect(all.first?.isComplete == false)
    }

    @Test("Every snapshot is a whole picture, and pending only shrinks")
    func snapshotsAreCumulative() async throws {
        let sut = FilteredCatalog(source: source(), engine: Fix.engine())

        let all = try await snapshots(sut)

        // Completion order is a race, so what is asserted is the shape rather
        // than which kind won: nothing is ever lost between snapshots, and a
        // caller can replace its state with each one instead of accumulating.
        var arrived = 0
        var outstanding = 3
        for snapshot in all {
            #expect(snapshot.byKind.count >= arrived)
            #expect(snapshot.pending.count <= outstanding)
            #expect(snapshot.byKind.count + snapshot.pending.count == 3)
            arrived = snapshot.byKind.count
            outstanding = snapshot.pending.count
        }
        #expect(all.last?.isComplete == true)
    }

    @Test("A kind that came back empty is not the same as one still coming")
    func pendingIsDistinctFromEmpty() async throws {
        let source = StubCatalogSource(pagesByKind: [
            .artist: [Fix.page([], hasMore: false)],
            .song: [Fix.page((0..<5).map { Fix.songItem($0) }, hasMore: false)],
        ])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let all = try await snapshots(sut, budgets: [.artist: 6, .song: 24])

        // Both read as "no items", and the screen has to tell them apart to
        // choose between a spinner and "nothing matched".
        #expect(all.first?.isPending(.artist) == true)
        #expect(all.last?.isPending(.artist) == false)
        #expect(all.last?.items(of: .artist).isEmpty == true)
        #expect(all.last?.results(for: .artist) != nil)
    }

    @Test("The awaited search ends where the incremental one does")
    func awaitedMatchesFinalSnapshot() async throws {
        let streamed = try await snapshots(
            FilteredCatalog(source: source(), engine: Fix.engine())
        ).last
        let awaited = try await FilteredCatalog(source: source(), engine: Fix.engine())
            .search(term: "x", budgets: [.artist: 6, .album: 6, .song: 24])

        // One is implemented in terms of the other, and this is the test that
        // notices if that stops being true.
        #expect(awaited.items.map(\.id) == streamed?.items.map(\.id))
        #expect(awaited.isComplete)
        #expect(awaited.pending.isEmpty)
    }

    @Test("A degenerate incremental search yields nothing and asks for nothing")
    func degenerateYieldsNothing() async throws {
        let source = source()
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let all = try await snapshots(sut, budgets: [:])

        #expect(all.isEmpty)
        #expect(await source.searchCalls.isEmpty)
    }
}

@Suite("Children and re-checks")
struct ChildrenTests {
    @Test("Playlist entries are filtered track by track")
    func filtersPlaylistEntries() async throws {
        let playlist = CatalogID(.playlist, "p1")
        let tracks = (0..<6).map { Fix.songItem($0, rating: $0.isMultiple(of: 2) ? .clean : .explicit) }
        let source = StubCatalogSource(children: [playlist: tracks])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.children(of: playlist)

        #expect(results.items.count == 3)
        #expect(results.blocked.count == 3)
    }

    @Test("The player's pre-playback re-check resolves ancestry when it is missing")
    func verdictResolvesAncestry() async throws {
        let source = StubCatalogSource(
            ancestry: [Fix.song(0): [Ancestor(id: Fix.artist)]]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine(.denyPlusAuto, [.deny(Fix.artist)]))

        let verdict = try await sut.verdict(for: Fix.songItem(0, rating: .clean))

        #expect(verdict == .blocked(.deniedByParent(Fix.artist)))
    }

    @Test("The re-check skips the lookup when ancestry is already attached")
    func verdictSkipsResolvedItems() async throws {
        let source = StubCatalogSource()
        let sut = FilteredCatalog(source: source, engine: Fix.engine())
        let item = Fix.songItem(0, rating: .clean, ancestors: [Ancestor(id: Fix.artist)])

        _ = try await sut.verdict(for: item)

        #expect(await source.ancestryCallCount == 0)
    }
}

@Suite("Caching")
struct CachingTests {
    @Test("A repeated lookup does not hit the source twice")
    func cachesItemLookups() async throws {
        let item = Fix.songItem(0)
        let source = StubCatalogSource(items: [Fix.song(0): item])
        let sut = CachingCatalogSource(wrapping: source, cache: InMemoryItemCache())

        _ = try await sut.item(for: Fix.song(0))
        _ = try await sut.item(for: Fix.song(0))

        #expect(await source.itemCallCount == 1)
    }

    @Test("A batch lookup keeps the caller's order, not the cache's")
    func batchPreservesOrder() async throws {
        let source = StubCatalogSource(items: [
            Fix.song(0): Fix.songItem(0),
            Fix.song(1): Fix.songItem(1),
            Fix.song(2): Fix.songItem(2),
        ])
        let sut = CachingCatalogSource(wrapping: source, cache: InMemoryItemCache())

        // Warm one in the middle, so serving from the cache and fetching the
        // rest would reshuffle if the order were not restored afterwards. A
        // recents screen is in time order and that order is the content.
        _ = try await sut.item(for: Fix.song(1))

        let ids = [Fix.song(2), Fix.song(1), Fix.song(0)]
        let items = try await sut.items(for: ids)

        #expect(items.map(\.id) == ids)
    }

    @Test("A batch lookup only asks for what is not cached")
    func batchSkipsCached() async throws {
        let source = StubCatalogSource(items: [
            Fix.song(0): Fix.songItem(0),
            Fix.song(1): Fix.songItem(1),
        ])
        let sut = CachingCatalogSource(wrapping: source, cache: InMemoryItemCache())

        _ = try await sut.item(for: Fix.song(0))
        let before = await source.itemCallCount

        _ = try await sut.items(for: [Fix.song(0), Fix.song(1)])

        // The stub has no batch of its own, so it falls back to one call per
        // item — which is exactly what makes the count readable here. One more
        // call, for the one that was missing.
        #expect(await source.itemCallCount == before + 1)
    }

    @Test("A batch lookup drops identifiers that no longer resolve")
    func batchDropsMissing() async throws {
        let source = StubCatalogSource(items: [Fix.song(0): Fix.songItem(0)])
        let sut = CachingCatalogSource(wrapping: source, cache: InMemoryItemCache())

        let items = try await sut.items(for: [Fix.song(0), Fix.song(99)])

        // Delisted items are absent rather than reported: every caller of this
        // is rendering a list, where the right answer is not to show it.
        #expect(items.map(\.id) == [Fix.song(0)])
    }

    @Test("Only unresolved items are sent for ancestry")
    func onlyFetchesMissingAncestry() async throws {
        let source = StubCatalogSource(ancestry: [Fix.song(1): [Ancestor(id: Fix.artist)]])
        let sut = CachingCatalogSource(wrapping: source, cache: InMemoryItemCache())

        let items = [
            Fix.songItem(0, ancestors: [Ancestor(id: Fix.album)]),
            Fix.songItem(1),
        ]
        _ = try await sut.resolveAncestry(for: items)

        #expect(await source.ancestryResolvedCount == 1)
    }

    @Test("Ancestry resolution preserves the source's ordering")
    func preservesOrdering() async throws {
        let source = StubCatalogSource(ancestry: [Fix.song(1): [Ancestor(id: Fix.artist)]])
        let sut = CachingCatalogSource(wrapping: source, cache: InMemoryItemCache())

        let items = [
            Fix.songItem(0, ancestors: [Ancestor(id: Fix.album)]),
            Fix.songItem(1),
            Fix.songItem(2, ancestors: [Ancestor(id: Fix.album)]),
        ]
        let resolved = try await sut.resolveAncestry(for: items)

        #expect(resolved.map(\.id) == items.map(\.id))
    }

    @Test("Searches are not cached — a stale page is worse than a slow one")
    func searchesAreNotCached() async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(4), Fix.mixedPage(4, startingAt: 4)])
        let sut = CachingCatalogSource(wrapping: source, cache: InMemoryItemCache())

        _ = try await sut.search(term: "x", kinds: [.song], limit: 4, offset: 0)
        _ = try await sut.search(term: "x", kinds: [.song], limit: 4, offset: 0)

        #expect(await source.searchCalls.count == 2)
    }
}
