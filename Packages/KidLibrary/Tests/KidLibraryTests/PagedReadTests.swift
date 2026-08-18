import Foundation
import Testing

import CatalogKit
import FamilyStore
import PolicyEngine

@testable import KidLibrary

/// A playlist long enough that the paging matters, built through the provider
/// rather than the library so the setup is not itself three hundred judgements.
@MainActor
private func longPlaylist(_ harness: Harness, count: Int) async throws -> PlaylistHandle {
    let songs = (0..<count).map {
        LibrarySong(item: CatalogItem(id: Fix.bulk($0), title: "Song \($0)", rating: .clean))
    }
    return try await harness.cloudKit.createPlaylist(named: "Long", songs: songs).handle
}

/// **The size of a request was invisible to every double in this package**, and
/// a whole playlist's worth of songs rode in on that. These are the assertions
/// that were not possible before `StubCatalog` recorded what it was asked for.
@Suite("Reading a long list a page at a time")
@MainActor
struct PagedReads {
    @Test("Three hundred songs are asked for in pages, not in one request")
    func longListIsPaged() async throws {
        let harness = try Harness()
        let handle = try await longPlaylist(harness, count: 316)

        _ = try await harness.library.songs(in: handle)

        let sizes = harness.catalog.itemRequestSizes
        #expect(sizes.count == 11, "316 rows in pages of 30 is eleven requests")
        #expect(sizes.allSatisfy { $0 <= CatalogFetchLimit.pageSize })
        #expect(sizes.reduce(0, +) == 316, "every row was asked for exactly once")
    }

    /// The ceiling that started all of this. A page size below every cap in the
    /// table means no read can breach one however long the list is — this is
    /// that claim, made against the requests rather than against the arithmetic.
    @Test("No request ever approaches Apple's cap")
    func noRequestNearsTheCap() async throws {
        let harness = try Harness()
        let handle = try await longPlaylist(harness, count: 316)

        _ = try await harness.library.songs(in: handle)

        #expect(
            harness.catalog.itemRequestSizes.allSatisfy {
                $0 <= CatalogFetchLimit.maxIDs(for: .song)
            }
        )
        #expect(harness.catalog.itemRequestSizes.contains { $0 > 0 })
    }

    @Test("A short list is still one request")
    func shortListIsOneRequest() async throws {
        let harness = try Harness()
        let handle = try await longPlaylist(harness, count: 12)

        _ = try await harness.library.songs(in: handle)

        #expect(harness.catalog.itemRequestSizes == [12])
    }

    /// **The ordering guarantee, which is the reason to page at all.** Pages run
    /// concurrently and land out of order; what a screen is shown must not. Every
    /// snapshot has to be a prefix of the final list — never a longer list with a
    /// hole in it, and never a reordering of what was already drawn.
    @Test("Every snapshot is a prefix of the one after it")
    func snapshotsOnlyGrowDownward() async throws {
        let harness = try Harness()
        let handle = try await longPlaylist(harness, count: 316)

        var seen: [[CatalogID]] = []
        for await snapshot in harness.library.songsIncrementally(in: handle) {
            seen.append(snapshot.items.map(\.id))
        }

        #expect(seen.count > 1, "a paged read of 316 rows should report more than once")
        for (earlier, later) in zip(seen, seen.dropFirst()) {
            #expect(later.count > earlier.count, "each snapshot adds rows")
            #expect(
                Array(later.prefix(earlier.count)) == earlier,
                "a snapshot rewrote rows that were already on screen"
            )
        }
        #expect(seen.last?.count == 316)
    }

    @Test("The first snapshot is the top of the list, and arrives before the rest")
    func theTopComesFirst() async throws {
        let harness = try Harness()
        let handle = try await longPlaylist(harness, count: 316)

        var first: LibraryResults?
        for await snapshot in harness.library.songsIncrementally(in: handle) {
            if first == nil { first = snapshot }
        }

        let opening = try #require(first)
        #expect(opening.items.count == CatalogFetchLimit.pageSize)
        #expect(opening.items.first?.id == Fix.bulk(0))
        #expect(opening.items.last?.id == Fix.bulk(CatalogFetchLimit.pageSize - 1))
    }

    /// Zero has to mean finished and nothing else, or a list that stops short is
    /// indistinguishable from one that ended.
    @Test("Pending counts the tail, and reaches zero exactly once at the end")
    func pendingCountsTheTail() async throws {
        let harness = try Harness()
        let handle = try await longPlaylist(harness, count: 316)

        var pendings: [Int] = []
        for await snapshot in harness.library.songsIncrementally(in: handle) {
            #expect(snapshot.items.count + snapshot.pending == 316)
            pendings.append(snapshot.pending)
        }

        #expect(pendings.last == 0)
        #expect(pendings.dropLast().allSatisfy { $0 > 0 })
        #expect(pendings == pendings.sorted(by: >), "pending only ever falls")
    }

    /// **A page failing must not empty the ones above it.** The old read was one
    /// request, so a failure took the whole list; now the tail of a long playlist
    /// going missing has to leave the top of it on screen.
    @Test("One page failing keeps the rest of the list")
    func oneFailedPageKeepsTheRest() async throws {
        let harness = try Harness()
        let handle = try await longPlaylist(harness, count: 316)
        // A row in the last page, so the failure is squarely in the tail.
        harness.catalog.failLookup(of: Fix.bulk(310))

        let results = try await harness.library.songs(in: handle)

        #expect(results.isResolved == false, "a page that did not answer is not resolved")
        #expect(results.items.count == 300, "the ten pages that answered are still here")
        #expect(results.items.first?.id == Fix.bulk(0))
        #expect(results.pending == 0, "finished, even though one page failed")
        // The sixteen that did not resolve are blocked rather than dropped, and
        // blocked as *unrated* — which is the same verdict the whole read used to
        // collapse to when the single request failed. The difference is that it
        // is now sixteen rows instead of three hundred and sixteen.
        #expect(results.blocked.count == 16)
        #expect(results.blocked.allSatisfy { $0.reason == .unrated })
    }

    /// The batched read is the last snapshot of the paged one, by construction.
    /// Asserted rather than assumed, because the day they diverge is the day a
    /// caller that awaits the whole list sees something different from the screen
    /// beside it.
    @Test("The batched answer is the paged one's last snapshot")
    func batchedMatchesPaged() async throws {
        let harness = try Harness()
        let handle = try await longPlaylist(harness, count: 316)

        var last = LibraryResults.empty
        for await snapshot in harness.library.songsIncrementally(in: handle) { last = snapshot }
        let batched = try await harness.library.songs(in: handle)

        #expect(batched.items.map(\.id) == last.items.map(\.id))
        #expect(batched.pending == last.pending)
        #expect(batched.isResolved == last.isResolved)
    }

    /// The browser reads every favorite and every playlist entry as one value,
    /// which in the store this was written against is 470 song identifiers.
    @Test("The library browser pages too, and its last snapshot is the whole library")
    func browserPagesAsWell() async throws {
        let harness = try Harness()
        _ = try await longPlaylist(harness, count: 316)

        var snapshots: [LibraryContents] = []
        for await contents in harness.library.contentsIncrementally() {
            snapshots.append(contents)
        }

        #expect(snapshots.count > 1)
        #expect(harness.catalog.itemRequestSizes.allSatisfy { $0 <= CatalogFetchLimit.pageSize })
        #expect(snapshots.last?.songs.count == 316)
        // Growing downward here as well: a column being filtered as a kid types
        // must not reorder under them either.
        for (earlier, later) in zip(snapshots, snapshots.dropFirst()) {
            #expect(later.songs.count >= earlier.songs.count)
        }
    }
}
