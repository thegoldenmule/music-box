import Foundation
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let loud = CatalogID(.artist, "artist-loud")
    static let quiet = CatalogID(.artist, "artist-quiet")
    static let song = CatalogID(.song, "song-A")
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
}

private func block(
    _ name: String,
    artist: CatalogID? = Fix.loud,
    kind: ItemKind = .song,
    reach: BlockReach = .unseen,
    reason: BlockReason = .explicitContent,
    origin: PlaybackOrigin = .home,
    minutes: Double = 0
) -> ReviewedBlock {
    ReviewedBlock(
        event: BlockEvent(
            itemID: CatalogID(kind, "id-\(name)"),
            displayName: name,
            artistID: artist,
            rating: .explicit,
            at: Fix.t0.addingTimeInterval(minutes * 60),
            reach: reach,
            reason: reason,
            origin: origin
        )
    )
}

@Suite("Grouping blocks")
struct Grouping {
    @Test("Rows for one artist collapse to one group")
    func collapses() {
        let groups = BlockGroup.group([block("One"), block("Two"), block("Three")])
        #expect(groups.count == 1)
        #expect(groups.first?.total == 3)
    }

    /// Never one number. The unseen count is a fact about our over-fetch loop;
    /// summing them reports our own machinery as things the child went after.
    @Test("Reached and unseen are counted separately")
    func countsAreSplit() {
        let groups = BlockGroup.group([
            block("One", reach: .reached),
            block("Two"),
            block("Three"),
        ])
        #expect(groups.first?.reached == 1)
        #expect(groups.first?.unseen == 2)
    }

    @Test("What the kid reached for sorts above what we filtered for them")
    func reachedSortsFirst() {
        let groups = BlockGroup.group([
            block("Loud A", artist: Fix.loud, minutes: 10),
            block("Loud B", artist: Fix.loud, minutes: 11),
            block("Loud C", artist: Fix.loud, minutes: 12),
            block("Quiet A", artist: Fix.quiet, reach: .reached, minutes: 1),
        ])
        // The quiet artist has one row against three, and it is the one that
        // describes something the child did.
        #expect(groups.first?.artistID == Fix.quiet)
    }

    @Test("A row that never resolved an artist is grouped by name, not dropped")
    func noLineage() {
        let groups = BlockGroup.group([
            block("Orphan", artist: nil),
            block("Orphan", artist: nil),
            block("Other", artist: nil),
        ])
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.artistID == nil })
    }

    @Test("The sample is one the kid reached for when there is one")
    func sampleIsReached() {
        let groups = BlockGroup.group([
            block("Unseen", minutes: 30),
            block("Tapped", reach: .reached, origin: .search(term: "monster"), minutes: 1),
        ])
        // Latest would have picked the unseen row; the reached one is what makes
        // the group a sentence a parent recognises.
        #expect(groups.first?.sample.displayName == "Tapped")
        #expect(groups.first?.sample.origin == .search(term: "monster"))
    }

    @Test("With nothing reached, the sample is the most recent")
    func sampleFallsBackToLatest() {
        let groups = BlockGroup.group([
            block("Older", minutes: 1),
            block("Newer", minutes: 5),
        ])
        #expect(groups.first?.sample.displayName == "Newer")
    }

    @Test("A group keeps every reason that caught something in it")
    func reasonsAccumulate() {
        let groups = BlockGroup.group([
            block("One", reason: .explicitContent),
            block("Two", reason: .unrated),
            block("Three", reason: .explicitContent),
        ])
        #expect(groups.first?.reasons == [.explicitContent, .unrated])
    }

    @Test("A group is named after the artist when the artist itself was blocked")
    func artistNameWins() {
        let groups = BlockGroup.group([
            block("A Track", minutes: 9),
            block("The Loud Band", kind: .artist, minutes: 1),
        ])
        #expect(groups.first?.displayName == "The Loud Band")
    }

    @Test("First and latest bracket the group")
    func timeSpan() {
        let groups = BlockGroup.group([
            block("One", minutes: 5),
            block("Two", minutes: 1),
            block("Three", minutes: 9),
        ])
        #expect(groups.first?.firstAt == Fix.t0.addingTimeInterval(60))
        #expect(groups.first?.latestAt == Fix.t0.addingTimeInterval(9 * 60))
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(BlockGroup.group([]).isEmpty)
    }
}
