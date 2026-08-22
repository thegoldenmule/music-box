import Foundation
import Testing

import CatalogKit
import FamilyStore
import PolicyEngine

@testable import KidLibrary

/// A playlist long enough that paging matters, built without judging 300 rows.
@MainActor
private func longPlaylist(_ harness: Harness, count: Int) async throws -> PlaylistHandle {
    let songs = (0..<count).map {
        LibrarySong(item: CatalogItem(id: Fix.bulk($0), title: "Song \($0)", rating: .clean))
    }
    return try await harness.cloudKit.createPlaylist(named: "Long", songs: songs).handle
}

/// Request size was invisible to every double — these needed `StubCatalog`.
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

    /// A page size below every cap means no read can breach one, however long.
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

    /// Pages land out of order, but every snapshot must still be a prefix.
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

        // A contiguous prefix from the very top, which is the whole claim in the
        // name. **Not one page**, which is what this used to assert and is a
        // race rather than a rule: `judged` runs `inFlight` pages at once and
        // yields only when the settled prefix grows, so pages 1 and 2 landing
        // before page 0 settles all three and makes the first snapshot 90 rows.
        // That is the design working — the guarantee is that nothing arrives
        // with a hole in it, not that the pages resolve in the order they were
        // asked for. Asserting the tighter thing failed about a third of the
        // time on this machine and had nothing to do with the code under test.
        #expect(opening.items.count >= CatalogFetchLimit.pageSize)
        #expect(
            opening.items.map(\.id) == (0..<opening.items.count).map(Fix.bulk),
            "the first snapshot is not the top of the list, in order"
        )
    }

    /// Zero must mean finished, or a short stop looks like the end.
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

    /// A failed page mustn't empty pages above it, unlike the old one request.
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
        // The sixteen that didn't resolve are blocked as unrated, not dropped.
        #expect(results.blocked.count == 16)
        #expect(results.blocked.allSatisfy { $0.reason == .unrated })
    }

    /// Batched must equal the paged read's last snapshot, or two callers disagree.
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

    /// The browser reads every favorite and entry as one value — 470 ids here.
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
        // Grows downward here too — filtering as a kid types must not reorder it.
        for (earlier, later) in zip(snapshots, snapshots.dropFirst()) {
            #expect(later.songs.count >= earlier.songs.count)
        }
    }
}
