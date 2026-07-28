import Foundation
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let loud = CatalogID(.artist, "artist-loud")
    static let quiet = CatalogID(.artist, "artist-quiet")
    static let album = CatalogID(.album, "album-A")
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let interval = DateInterval(start: t0, end: t0.addingTimeInterval(7 * 86_400))
}

private func play(
    _ name: String,
    artist: CatalogID? = Fix.loud,
    seconds: Int = 60,
    minutes: Double = 0
) -> PlayEvent {
    PlayEvent(
        songID: CatalogID(.song, "id-\(name)"),
        albumID: Fix.album,
        artistID: artist,
        displayName: name,
        rating: .clean,
        at: Fix.t0.addingTimeInterval(minutes * 60),
        secondsPlayed: seconds,
        origin: .home
    )
}

private func window(
    plays: [PlayEvent] = [],
    searches: [SearchEvent] = [],
    blocks: [ReviewedBlock] = []
) -> ReviewWindow {
    ReviewWindow(
        kidID: UUID(),
        interval: Fix.interval,
        plays: plays,
        searches: searches,
        blocks: blocks,
        unreadable: 0,
        builtAt: Fix.t0,
        coverage: .complete
    )
}

@Suite("Deriving a week")
struct Summarising {
    @Test("Artists are ranked by time, songs by how often they were played")
    func rankings() {
        // A kid who leaves one album on all afternoon was into that album,
        // however few taps it took — so the two lists rank differently.
        let summary = WeeklySummary.of(
            window(plays: [
                play("Long", artist: Fix.quiet, seconds: 600),
                play("Short A", artist: Fix.loud, seconds: 30),
                play("Short A", artist: Fix.loud, seconds: 30, minutes: 1),
                play("Short B", artist: Fix.loud, seconds: 30, minutes: 2),
            ]),
            previouslyHeard: []
        )
        #expect(summary.topArtists.first?.id == Fix.quiet.rawValue)
        #expect(summary.topSongs.first?.name == "Short A")
        #expect(summary.topSongs.first?.plays == 2)
        #expect(summary.totalListeningSeconds == 690)
    }

    /// The row still counts toward the total. It simply does not appear in a
    /// list it has no key for.
    @Test("A play with no artist counts toward listening time and groups nowhere")
    func missingLineage() {
        let summary = WeeklySummary.of(
            window(plays: [play("Orphan", artist: nil, seconds: 120)]),
            previouslyHeard: []
        )
        #expect(summary.totalListeningSeconds == 120)
        #expect(summary.topArtists.isEmpty)
        #expect(summary.topSongs.count == 1)
    }

    @Test("First-time-heard excludes anything played before the window")
    func firstTime() {
        let old = CatalogID(.song, "id-Known")
        let summary = WeeklySummary.of(
            window(plays: [play("Known"), play("New", minutes: 1)]),
            previouslyHeard: [old]
        )
        #expect(summary.firstTimeHeard.map(\.name) == ["New"])
    }

    /// Passing `nil` rather than an empty set is how a caller says "I could not
    /// answer" — and an empty list is the honest result, not a week where every
    /// song looks new.
    @Test("Without knowing what came before, nothing is claimed as new")
    func firstTimeUnknowable() {
        let summary = WeeklySummary.of(
            window(plays: [play("Anything")]),
            previouslyHeard: nil
        )
        #expect(summary.firstTimeHeard.isEmpty)
    }

    @Test("Only blocks the kid reached for are counted next to the other numbers")
    func reachedBlocks() {
        let reached = ReviewedBlock(
            event: BlockEvent(
                itemID: CatalogID(.song, "s1"),
                displayName: "Tapped",
                artistID: Fix.loud,
                at: Fix.t0,
                reach: .reached,
                reason: .explicitContent,
                origin: .home
            )
        )
        let unseen = ReviewedBlock(
            event: BlockEvent(
                itemID: CatalogID(.song, "s2"),
                displayName: "Filtered",
                artistID: Fix.loud,
                at: Fix.t0,
                reach: .unseen,
                reason: .explicitContent,
                origin: .home
            )
        )
        let summary = WeeklySummary.of(
            window(blocks: [reached, unseen, unseen]),
            previouslyHeard: []
        )
        #expect(summary.reachedBlockCount == 1)
        #expect(summary.blocksByArtist.first?.unseen == 2)
    }

    @Test("An empty week summarises to zeroes rather than to nothing")
    func emptyWeek() {
        let summary = WeeklySummary.of(window(), previouslyHeard: [])
        #expect(summary.totalListeningSeconds == 0)
        #expect(summary.searchCount == 0)
        #expect(summary.topArtists.isEmpty)
        #expect(summary.interval == Fix.interval)
    }

    @Test("Lists are capped so a summary stays readable in one go")
    func capped() {
        let plays = (0..<20).map {
            play("Song \($0)", artist: CatalogID(.artist, "a\($0)"), minutes: Double($0))
        }
        let summary = WeeklySummary.of(window(plays: plays), previouslyHeard: [])
        #expect(summary.topArtists.count == WeeklySummary.topCount)
        #expect(summary.topSongs.count == WeeklySummary.topCount)
    }
}
