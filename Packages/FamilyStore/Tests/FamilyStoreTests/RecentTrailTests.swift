import Foundation
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let band = CatalogID(.artist, "artist-band")
    static let other = CatalogID(.artist, "artist-other")
    static let record = CatalogID(.album, "album-record")
    static let second = CatalogID(.album, "album-second")
    static let track = CatalogID(.song, "song-track")
    static let list = CatalogID(.playlist, "playlist-list")
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
}

/// One arrival. `minutes` keeps the ordering readable.
private func visit(
    _ id: CatalogID,
    album: CatalogID? = nil,
    artist: CatalogID? = nil,
    manner: VisitManner = .opened,
    minutes: Double
) -> VisitEvent {
    VisitEvent(
        itemID: id,
        displayName: id.rawValue,
        albumID: album,
        artistID: artist,
        manner: manner,
        at: Fix.t0.addingTimeInterval(minutes * 60)
    )
}

private func trail(_ visits: [VisitEvent]) -> [CatalogID] {
    RecentTrail.folding(visits).map(\.catalogID)
}

// MARK: -

@Suite("Walking a trail")
struct Walking {
    /// The rule, in one line: only the deepest thing reached in an excursion
    /// survives it.
    @Test("Artist, then their album, then a track from it leaves only the track")
    func fullDescent() {
        let result = trail([
            visit(Fix.band, minutes: 1),
            visit(Fix.record, artist: Fix.band, minutes: 2),
            visit(Fix.track, album: Fix.record, artist: Fix.band, manner: .played, minutes: 3),
        ])
        #expect(result == [Fix.track])
    }

    @Test("An artist opened and left behind is what shows")
    func artistDeadEnd() {
        #expect(trail([visit(Fix.band, minutes: 1)]) == [Fix.band])
    }

    @Test("An album no track was played from is what shows")
    func albumDeadEnd() {
        let result = trail([
            visit(Fix.band, minutes: 1),
            visit(Fix.record, artist: Fix.band, minutes: 2),
        ])
        #expect(result == [Fix.record])
    }

    /// Each excursion that dead-ends contributes its deepest item. They looked
    /// at the first album and never played from it, so it stays.
    @Test("Two albums by one artist both show, and the artist does not")
    func twoAlbumsOneArtist() {
        let result = trail([
            visit(Fix.band, minutes: 1),
            visit(Fix.record, artist: Fix.band, minutes: 2),
            visit(Fix.second, artist: Fix.band, minutes: 3),
        ])
        #expect(result == [Fix.second, Fix.record])
    }

    @Test("A song played straight from search stands on its own")
    func songWithNoExcursion() {
        let result = trail([
            visit(Fix.track, album: Fix.record, artist: Fix.band, manner: .played, minutes: 1)
        ])
        #expect(result == [Fix.track])
    }

    /// A song has no descendants, so going back to the album is a new arrival
    /// rather than a supersession — and they *are* on the album now.
    @Test("Back to the album after playing a track keeps both")
    func backToTheAlbum() {
        let result = trail([
            visit(Fix.record, artist: Fix.band, minutes: 1),
            visit(Fix.track, album: Fix.record, artist: Fix.band, manner: .played, minutes: 2),
            visit(Fix.record, artist: Fix.band, minutes: 3),
        ])
        #expect(result == [Fix.record, Fix.track])
    }

    @Test("An unrelated artist opens a new excursion and leaves the old one alone")
    func unrelatedExcursion() {
        let result = trail([
            visit(Fix.record, artist: Fix.band, minutes: 1),
            visit(Fix.other, minutes: 2),
        ])
        #expect(result == [Fix.other, Fix.record])
    }
}

// MARK: -

@Suite("Where the walk deliberately does nothing")
struct Limits {
    /// Guessing would be the alternative, and the cost of guessing wrong is a
    /// wrong shelf rather than one extra tile.
    @Test("An album whose artist never resolved does not supersede that artist")
    func missingLineage() {
        let result = trail([
            visit(Fix.band, minutes: 1),
            visit(Fix.record, artist: nil, minutes: 2),
        ])
        #expect(result == [Fix.record, Fix.band])
    }

    /// Nothing carries the playlist a song was played from, so the walk cannot
    /// know — and says so by leaving both.
    @Test("A playlist is never an ancestor")
    func playlistIsNotAContainer() {
        let result = trail([
            visit(Fix.list, minutes: 1),
            visit(Fix.track, album: Fix.record, artist: Fix.band, manner: .played, minutes: 2),
        ])
        #expect(result == [Fix.track, Fix.list])
    }
}

// MARK: -

@Suite("Staying idempotent")
struct Idempotency {
    /// A `.task` firing twice, a screen reappearing under a dismissed sheet, a
    /// "Try again" button — all of them land here and none of them should show
    /// twice.
    @Test("The same album twice is one entry")
    func sameThingTwice() {
        let result = trail([
            visit(Fix.record, artist: Fix.band, minutes: 1),
            visit(Fix.record, artist: Fix.band, minutes: 2),
        ])
        #expect(result == [Fix.record])
    }

    @Test("Revisiting something older moves it to the front")
    func revisitMovesForward() {
        let result = trail([
            visit(Fix.record, artist: Fix.band, minutes: 1),
            visit(Fix.other, minutes: 2),
            visit(Fix.record, artist: Fix.band, minutes: 3),
        ])
        #expect(result == [Fix.record, Fix.other])
    }

    @Test("A revisit carries the newer timestamp")
    func revisitRefreshesTime() {
        let entries = RecentTrail.folding([
            visit(Fix.record, artist: Fix.band, minutes: 1),
            visit(Fix.record, artist: Fix.band, minutes: 9),
        ])
        #expect(entries.first?.at == Fix.t0.addingTimeInterval(9 * 60))
    }

    @Test("A song played twice appears once")
    func songTwice() {
        let result = trail([
            visit(Fix.track, album: Fix.record, artist: Fix.band, manner: .played, minutes: 1),
            visit(Fix.track, album: Fix.record, artist: Fix.band, manner: .played, minutes: 2),
        ])
        #expect(result == [Fix.track])
    }
}

// MARK: -

@Suite("Bounds")
struct Bounds {
    @Test("The trail trims to its cap, keeping the newest")
    func capped() {
        let visits = (0..<(RecentTrail.cap + 10)).map {
            visit(CatalogID(.artist, "artist-\($0)"), minutes: Double($0))
        }
        let result = RecentTrail.folding(visits)
        #expect(result.count == RecentTrail.cap)
        #expect(result.first?.catalogID == CatalogID(.artist, "artist-\(RecentTrail.cap + 9)"))
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(RecentTrail.folding([]).isEmpty)
    }

    /// The property the whole design rests on: replaying a stream and folding it
    /// one arrival at a time are the same operation, so a rebuilt shelf and a
    /// maintained shelf cannot disagree.
    @Test("Folding a stream equals applying it one at a time")
    func foldMatchesIncremental() {
        let visits = [
            visit(Fix.band, minutes: 1),
            visit(Fix.record, artist: Fix.band, minutes: 2),
            visit(Fix.other, minutes: 3),
            visit(Fix.track, album: Fix.record, artist: Fix.band, manner: .played, minutes: 4),
            visit(Fix.second, artist: Fix.band, minutes: 5),
        ]

        var incremental: [RecentEntry] = []
        for visit in visits {
            incremental = RecentTrail.applying(visit, to: incremental)
        }

        #expect(incremental == RecentTrail.folding(visits))
    }
}
