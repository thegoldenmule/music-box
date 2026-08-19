import Testing

import CatalogKit
import PolicyEngine

/// Apple's caps aren't provable here; these pin down our half: nothing is lost.
@Suite("Catalog fetch limits")
struct CatalogFetchLimitTests {
    @Test(
        "Apple's documented cap per kind",
        arguments: [
            (ItemKind.song, 300),
            (ItemKind.album, 100),
            (ItemKind.artist, 25),
            (ItemKind.playlist, 25),
        ]
    )
    func caps(kind: ItemKind, expected: Int) {
        #expect(CatalogFetchLimit.maxIDs(for: kind) == expected)
    }

    @Test("Nothing to fetch is no request, not an empty one")
    func emptyMakesNoBatch() {
        #expect(CatalogFetchLimit.batches([Int](), for: .song).isEmpty)
    }

    @Test("A list within the cap stays one request")
    func withinCapIsOneBatch() {
        let ids = Array(1...300)
        #expect(CatalogFetchLimit.batches(ids, for: .song) == [ids])
    }

    /// The real bug: a 316-song playlist failed whole and rendered empty.
    @Test("One over the cap splits rather than fails")
    func justOverCapSplits() {
        let batches = CatalogFetchLimit.batches(Array(1...316), for: .song)

        #expect(batches.count == 2)
        #expect(batches[0].count == 300)
        #expect(batches[1].count == 16)
    }

    @Test(
        "Every batch is within the cap, and the whole list survives in order",
        arguments: [ItemKind.song, .album, .artist, .playlist]
    )
    func splitsLosingNothing(kind: ItemKind) {
        let ids = Array(1...1000)
        let batches = CatalogFetchLimit.batches(ids, for: kind)

        #expect(batches.allSatisfy { $0.count <= CatalogFetchLimit.maxIDs(for: kind) })
        #expect(batches.allSatisfy { !$0.isEmpty })
        #expect(batches.flatMap { $0 } == ids)
    }

    /// Exact multiples are the off-by-one that leaves a trailing empty batch.
    @Test("An exact multiple of the cap leaves no empty batch behind")
    func exactMultipleLeavesNoRemainder() {
        let batches = CatalogFetchLimit.batches(Array(1...50), for: .artist)

        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.count == 25 })
    }
}
