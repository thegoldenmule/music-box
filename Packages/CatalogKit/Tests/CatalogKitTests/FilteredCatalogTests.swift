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

        _ = try await sut.search(term: "x", kinds: [.song], limit: 10)

        #expect(await source.searchCalls.first?.limit == 30)
    }

    @Test("A single request never exceeds the page ceiling")
    func respectsPageCeiling() async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(10, hasMore: false)])
        let config = FilteredCatalog.Configuration(overFetchMultiplier: 10, maxPageSize: 50)
        let sut = FilteredCatalog(source: source, engine: Fix.engine(), configuration: config)

        _ = try await sut.search(term: "x", kinds: [.song], limit: 25)

        #expect(await source.searchCalls.first?.limit == 50)
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
