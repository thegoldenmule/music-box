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

        // Five, not twenty-five: multiplier only has room below Apple's 25 cap.
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

        // Asking 75 was once a real 400; the stub alone wouldn't have caught it.
        let asked = await source.searchCalls.map(\.limit)
        #expect(asked.allSatisfy { $0 <= 25 })
        #expect(!asked.isEmpty)
    }

    @Test("A single request never exceeds the page ceiling")
    func respectsPageCeiling() async throws {
        let source = StubCatalogSource(pages: [Fix.mixedPage(10, hasMore: false)])
        // Ceiling below Apple's cap — exercises the ceiling, not a real page size.
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

    @Test("An item returned on two pages is judged once and shown once")
    func deduplicatesAcrossPages() async throws {
        // Relevance order can drift across offsets, so items can repeat pages.
        let source = StubCatalogSource(pages: [
            Fix.page((0..<4).map { Fix.songItem($0, rating: $0 == 3 ? .explicit : .clean) }),
            Fix.page((2..<8).map { Fix.songItem($0) }, hasMore: false),
        ])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", kinds: [.song], limit: 10)

        // On screen: a blank row-height gap, since `ForEach` keys on the id.
        let ids = results.items.map(\.id)
        #expect(ids == [0, 1, 2, 4, 5, 6, 7].map(Fix.song))
        #expect(ids.count == Set(ids).count)
        // And the repeat is not logged to the parent's report a second time.
        #expect(results.blocked.map(\.item.id) == [Fix.song(3)])
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
    /// Enough songs to swamp the other two kinds if they shared a budget.
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

        // The bug caught: a shared limit lets `prefix` cut every album/artist off.
        #expect(results.items(of: .artist).count == 3)
        #expect(results.items(of: .album).count == 4)
        #expect(results.items(of: .song).count == 24)
    }

    @Test("Each kind is asked for on its own, never in one mixed request")
    func neverMixesKindsInARequest() async throws {
        let source = source()
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        _ = try await sut.search(term: "x", budgets: [.artist: 6, .album: 6, .song: 24])

        // Why one loop per kind: a mixed request breaks hasMore and offset math.
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

        // Over-fetch is per kind: 2×3 for artists, songs clamped at 25.
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
        // Absent differs from present-and-empty; a filter needs both facts.
        #expect(results.results(for: .album) == nil)
        #expect(results.results(for: .song) != nil)
    }

    @Test("Artists survive UnratedBehavior.block, which would otherwise hide them all")
    func artistsAreNotBlockedAsUnrated() async throws {
        // No rating on artists; nil is normal, or unrated blocks them all.
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

        // Artists, songs, albums — tab order, so the two can't disagree.
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

        // Built from what came back, not what was asked, so no filter dead-ends.
        #expect(results.populatedKinds == [.artist, .song])
    }

    @Test("One kind giving up is reported, and does not read as the end")
    func gaveUpEarlyWinsOverReachedEnd() async throws {
        // Songs stay explicit, burning retries; artists finish on page one.
        let explicit = (0..<20).map { page in
            Fix.page((0..<4).map { Fix.songItem(page * 4 + $0, rating: .explicit) }, hasMore: true)
        }
        let source = StubCatalogSource(pagesByKind: [
            .song: explicit,
            .artist: [Fix.page([Fix.artistItem(0)], hasMore: false)],
        ])
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.search(term: "x", budgets: [.song: 10, .artist: 6])

        // "Stopped looking" must survive merging, or a partial reads as empty.
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

        // Asserts shape, not race order — nothing lost, state fully replaced.
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

        // Both read as "no items" — the screen must tell spinner from "no match".
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

        // One is built on the other; this test catches if that stops being true.
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

    @Test("An artist's top songs are filtered like anything else they are handed")
    func filtersTopSongs() async throws {
        let source = StubCatalogSource(
            topSongs: [
                Fix.artist: (0..<4).map {
                    Fix.songItem($0, rating: $0.isMultiple(of: 2) ? .clean : .explicit)
                }
            ]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.topSongs(of: Fix.artist)

        #expect(results.items.count == 2)
        #expect(results.blocked.count == 2)
    }

    /// Resolved before judging: top songs arrive from the catalog with no lineage.
    @Test("A deny on the artist reaches their top songs")
    func topSongsRespectArtistDeny() async throws {
        let source = StubCatalogSource(
            ancestry: [Fix.song(0): [Ancestor(id: Fix.artist)]],
            topSongs: [Fix.artist: [Fix.songItem(0)]]
        )
        let sut = FilteredCatalog(
            source: source,
            engine: Fix.engine(.denyPlusAuto, [.deny(Fix.artist)])
        )

        let results = try await sut.topSongs(of: Fix.artist)

        #expect(results.items.isEmpty)
        #expect(results.blocked.first?.reason == .deniedByParent(Fix.artist))
    }

    // MARK: - Related

    @Test("A deny reaches an adjacent artist, and only a deny can")
    func similarArtistsRespectDeny() async throws {
        let source = StubCatalogSource(
            similarArtists: [
                Fix.artist: [Fix.artistItem(1), Fix.artistItem(2), Fix.artistItem(3)]
            ]
        )
        let sut = FilteredCatalog(
            source: source,
            engine: Fix.engine(.denyPlusAuto, [.deny(CatalogID(.artist, "artist-2"))])
        )

        let results = try await sut.similarArtists(of: Fix.artist)

        #expect(results.items.count == 2)
        #expect(results.blocked.first?.reason == .deniedByParent(CatalogID(.artist, "artist-2")))
    }

    /// The asymmetry a related shelf has to be read against: artists carry no
    /// rating, so `unratedBehavior` cannot turn a tile down. What keeps the
    /// shelf honest is that every song *behind* the tile is judged on arrival —
    /// see the album case below, where the rating does bite.
    @Test("Blocking unrated items does not empty a shelf of artists")
    func similarArtistsAreNotRated() async throws {
        let source = StubCatalogSource(
            similarArtists: [Fix.artist: [Fix.artistItem(1), Fix.artistItem(2)]]
        )
        let sut = FilteredCatalog(
            source: source,
            engine: Fix.engine(.denyPlusAuto, [], unrated: .block)
        )

        let results = try await sut.similarArtists(of: Fix.artist)

        // Every one of them has a nil rating and every one of them is here.
        #expect(results.items.count == 2)
        #expect(results.blocked.isEmpty)
    }

    @Test("An explicit related album never becomes a tile")
    func relatedAlbumsAreRated() async throws {
        let source = StubCatalogSource(
            relatedAlbums: [
                Fix.album: (0..<4).map {
                    Fix.albumItem($0, rating: $0.isMultiple(of: 2) ? .clean : .explicit)
                }
            ]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let results = try await sut.relatedAlbums(of: Fix.album)

        #expect(results.items.count == 2)
        #expect(results.blocked.count == 2)
    }

    /// Level 1 has no related shelf at all — the gate for that lives in
    /// `Session.showsRelated`, but the engine is what makes it moot here.
    @Test("At level 1 an adjacent album is not on the allow list")
    func relatedAlbumsAreEmptyAtLevelOne() async throws {
        let source = StubCatalogSource(
            relatedAlbums: [Fix.album: [Fix.albumItem(1), Fix.albumItem(2)]]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine(.allowOnly, []))

        let results = try await sut.relatedAlbums(of: Fix.album)

        #expect(results.items.isEmpty)
        #expect(results.blocked.allSatisfy { $0.reason == .notOnAllowList })
    }

    @Test("Album credits come back whole when nothing is denied")
    func creditsAreReturned() async throws {
        let source = StubCatalogSource(
            artists: [Fix.album: [Fix.artistItem(1), Fix.artistItem(2)]]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine())

        let credits = try await sut.artists(of: Fix.album)

        #expect(credits.map(\.title) == ["Artist 1", "Artist 2"])
    }

    /// Ancestry keeps only the first artist; credits catch a denied co-credit too.
    @Test("A denied co-credit is dropped, and the record itself stays reachable")
    func deniedCreditIsDropped() async throws {
        let denied = CatalogID(.artist, "artist-2")
        let source = StubCatalogSource(
            artists: [Fix.album: [Fix.artistItem(1), Fix.artistItem(2)]]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine(.denyPlusAuto, [.deny(denied)]))

        let credits = try await sut.artists(of: Fix.album)

        #expect(credits.map(\.title) == ["Artist 1"])
    }

    /// Level 1's harder half: unlisted, not denied — its link opens onto nothing.
    @Test("Level 1 offers only credits the parent put on the list")
    func allowOnlyKeepsListedCredits() async throws {
        let listed = CatalogID(.artist, "artist-1")
        let source = StubCatalogSource(
            artists: [Fix.album: [Fix.artistItem(1), Fix.artistItem(2)]]
        )
        let sut = FilteredCatalog(source: source, engine: Fix.engine(.allowOnly, [.allow(listed)]))

        let credits = try await sut.artists(of: Fix.album)

        #expect(credits.map(\.title) == ["Artist 1"])
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

        // Warms the middle id; order must survive a cache-plus-fetch mix.
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

        // Stub has no batch, one call per item — one more, for the missing one.
        #expect(await source.itemCallCount == before + 1)
    }

    @Test("A batch lookup drops identifiers that no longer resolve")
    func batchDropsMissing() async throws {
        let source = StubCatalogSource(items: [Fix.song(0): Fix.songItem(0)])
        let sut = CachingCatalogSource(wrapping: source, cache: InMemoryItemCache())

        let items = try await sut.items(for: [Fix.song(0), Fix.song(99)])

        // Delisted items are absent, not reported — callers here render a list.
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

/// The one place this package guesses what an absent flag means, not a fact.
@Suite("Singles and records")
struct SingleReleaseTests {
    @Test(
        "The catalog's flag decides whenever there is one",
        arguments: [
            (true, 1, true),
            (true, 12, true),
            // A flagged single wins outright, even with many tracks.
            (false, 1, false),
            (false, 12, false),
        ]
    )
    func flagWins(isSingle: Bool, trackCount: Int, expected: Bool) {
        let album = Fix.albumItem(1, isSingle: isSingle, trackCount: trackCount)
        #expect(album.isSingleRelease == expected)
    }

    @Test(
        "With no flag, two tracks or fewer stands in for one",
        arguments: [(1, true), (2, true), (3, false), (12, false)]
    )
    func countStandsIn(trackCount: Int, expected: Bool) {
        let album = Fix.albumItem(1, isSingle: nil, trackCount: trackCount)
        #expect(album.isSingleRelease == expected)
    }

    /// Fails toward showing: a stray single is untidy; a hidden record is worse.
    @Test("Knowing nothing means it is a record")
    func unknownIsARecord() {
        #expect(!Fix.albumItem(1).isSingleRelease)
        #expect(!Fix.songItem(1).isSingleRelease)
    }
}
