import Foundation
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let band = CatalogID(.artist, "artist-band")
    static let other = CatalogID(.artist, "artist-other")
    static let record = CatalogID(.album, "album-record")
    static let second = CatalogID(.album, "album-second")
    static let list = CatalogID(.playlist, "playlist-list")
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func song(_ n: Int) -> CatalogID { CatalogID(.song, "song-\(n)") }
}

/// One arrival. `minutes` keeps the ordering readable and is the only thing
/// "contiguous" is decided from.
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

private func track(_ n: Int, on album: CatalogID, by artist: CatalogID, minutes: Double)
    -> VisitEvent
{
    visit(Fix.song(n), album: album, artist: artist, manner: .played, minutes: minutes)
}

private func shelf(_ visits: [VisitEvent]) -> [CatalogID] {
    RecentTrail.shelf(from: visits).map(\.catalogID)
}

// MARK: -

@Suite("Collapsing a run into its album")
struct Runs {
    @Test("Several tracks off one record become the record")
    func contiguousRunCollapses() {
        let result = shelf([
            track(1, on: Fix.record, by: Fix.band, minutes: 1),
            track(2, on: Fix.record, by: Fix.band, minutes: 2),
            track(3, on: Fix.record, by: Fix.band, minutes: 3),
        ])
        #expect(result == [Fix.record])
    }

    @Test("Opening a record and then playing from it is one run")
    func openThenPlay() {
        let result = shelf([
            visit(Fix.record, artist: Fix.band, minutes: 1),
            track(1, on: Fix.record, by: Fix.band, minutes: 2),
        ])
        #expect(result == [Fix.record])
    }

    /// One track is a track. Calling it the record would claim more than
    /// happened.
    @Test("A single track stays a track")
    func loneTrack() {
        let result = shelf([track(1, on: Fix.record, by: Fix.band, minutes: 1)])
        #expect(result == [Fix.song(1)])
    }

    @Test("A record opened and left alone stays the record")
    func loneAlbumView() {
        let result = shelf([visit(Fix.record, artist: Fix.band, minutes: 1)])
        #expect(result == [Fix.record])
    }

    /// Contiguous means contiguous. Hopping between two records is two visits
    /// to two records, not two runs of one.
    @Test("Tracks from two records interleaved do not collapse")
    func interleavedDoesNotCollapse() {
        let result = shelf([
            track(1, on: Fix.record, by: Fix.band, minutes: 1),
            track(2, on: Fix.second, by: Fix.band, minutes: 2),
            track(3, on: Fix.record, by: Fix.band, minutes: 3),
        ])
        #expect(Set(result) == [Fix.song(1), Fix.song(2), Fix.song(3)])
    }

    @Test("Two runs through two records give two records")
    func twoRuns() {
        let result = shelf([
            track(1, on: Fix.record, by: Fix.band, minutes: 1),
            track(2, on: Fix.record, by: Fix.band, minutes: 2),
            track(3, on: Fix.second, by: Fix.band, minutes: 3),
            track(4, on: Fix.second, by: Fix.band, minutes: 4),
        ])
        #expect(result == [Fix.second, Fix.record])
    }

    /// An artist has no album key, so it can never join a run — which is what
    /// stops a whole evening collapsing into one tile.
    @Test("An artist between two runs keeps them apart")
    func artistBreaksARun() {
        let result = shelf([
            track(1, on: Fix.record, by: Fix.band, minutes: 1),
            visit(Fix.other, minutes: 2),
            track(2, on: Fix.record, by: Fix.band, minutes: 3),
        ])
        #expect(Set(result) == [Fix.song(1), Fix.song(2), Fix.other])
    }
}

// MARK: -

@Suite("When an artist earns a tile")
struct Artists {
    /// The only thing an artist tile is for.
    @Test("An artist opened and left behind shows")
    func viewedOnly() {
        #expect(shelf([visit(Fix.band, minutes: 1)]) == [Fix.band])
    }

    @Test("An artist whose record is on the shelf does not")
    func supersededByAlbum() {
        let result = shelf([
            visit(Fix.band, minutes: 1),
            visit(Fix.record, artist: Fix.band, minutes: 2),
        ])
        #expect(result == [Fix.record])
    }

    @Test("An artist whose track is on the shelf does not")
    func supersededBySong() {
        let result = shelf([
            visit(Fix.band, minutes: 1),
            track(1, on: Fix.record, by: Fix.band, minutes: 2),
        ])
        #expect(result == [Fix.song(1)])
    }

    /// The artist whose work is present loses their tile; the one who was only
    /// looked at keeps theirs.
    @Test("Two artists, only one of them played")
    func oneOfTwoArtists() {
        let result = shelf([
            visit(Fix.band, minutes: 1),
            track(1, on: Fix.record, by: Fix.band, minutes: 2),
            visit(Fix.other, minutes: 3),
        ])
        #expect(result == [Fix.other, Fix.song(1)])
    }

    /// Rule 2 is applied after rule 3, so a track dropped in favour of its
    /// record still counts as that artist's work being present.
    @Test("An artist is covered by a record that replaced their track")
    func coveredThroughACollapsedRun() {
        let result = shelf([
            visit(Fix.band, minutes: 1),
            track(1, on: Fix.record, by: Fix.band, minutes: 2),
            track(2, on: Fix.record, by: Fix.band, minutes: 3),
        ])
        #expect(result == [Fix.record])
    }
}

// MARK: -

@Suite("When a song earns a tile")
struct Songs {
    @Test("A track whose record is shown is dropped")
    func droppedForItsAlbum() {
        let result = shelf([
            visit(Fix.record, artist: Fix.band, minutes: 1),
            visit(Fix.other, minutes: 2),
            track(1, on: Fix.record, by: Fix.band, minutes: 3),
        ])
        // The album was opened earlier and the track later; the album is the way
        // back to both.
        #expect(result == [Fix.other, Fix.record])
    }

    @Test("A track whose record is not shown survives")
    func keptWhenAlbumAbsent() {
        let result = shelf([
            visit(Fix.other, minutes: 1),
            track(1, on: Fix.record, by: Fix.band, minutes: 2),
        ])
        #expect(result == [Fix.song(1), Fix.other])
    }

    @Test("A track whose album never resolved survives")
    func missingLineage() {
        let result = shelf([
            visit(Fix.record, artist: Fix.band, minutes: 1),
            visit(Fix.other, minutes: 2),
            visit(Fix.song(1), album: nil, artist: nil, manner: .played, minutes: 3),
        ])
        #expect(result.contains(Fix.song(1)))
    }
}

// MARK: -

@Suite("Shape and bounds")
struct Shape {
    @Test("Newest first")
    func ordering() {
        let result = shelf([
            visit(Fix.band, minutes: 1),
            visit(Fix.other, minutes: 2),
            visit(Fix.list, minutes: 3),
        ])
        #expect(result == [Fix.list, Fix.other, Fix.band])
    }

    /// A `.task` firing twice, a screen reappearing under a dismissed sheet, a
    /// "Try again" — none of them should show twice.
    @Test("The same thing twice is one tile, at the later time")
    func idempotent() {
        let entries = RecentTrail.shelf(from: [
            visit(Fix.other, minutes: 1),
            visit(Fix.other, minutes: 9),
        ])
        #expect(entries.map(\.catalogID) == [Fix.other])
        #expect(entries.first?.at == Fix.t0.addingTimeInterval(9 * 60))
    }

    /// A run of tracks produces a nameless album tile; an earlier visit to that
    /// album has the name, and throwing it away would leave the shelf unable to
    /// draw offline.
    @Test("A name from an earlier visit survives a later nameless one")
    func nameSurvives() {
        let entries = RecentTrail.shelf(from: [
            visit(Fix.record, artist: Fix.band, minutes: 1),
            visit(Fix.other, minutes: 2),
            track(1, on: Fix.record, by: Fix.band, minutes: 3),
            track(2, on: Fix.record, by: Fix.band, minutes: 4),
        ])
        let album = entries.first { $0.catalogID == Fix.record }
        #expect(album?.displayName == Fix.record.rawValue)
    }

    @Test("A playlist is its own tile and joins no run")
    func playlists() {
        let result = shelf([
            visit(Fix.list, minutes: 1),
            track(1, on: Fix.record, by: Fix.band, minutes: 2),
        ])
        #expect(result == [Fix.song(1), Fix.list])
    }

    @Test("The shelf trims to its cap, keeping the newest")
    func capped() {
        let visits = (0..<(RecentTrail.cap + 10)).map {
            visit(CatalogID(.artist, "artist-\($0)"), minutes: Double($0))
        }
        let result = RecentTrail.shelf(from: visits)
        #expect(result.count == RecentTrail.cap)
        #expect(result.first?.catalogID == CatalogID(.artist, "artist-\(RecentTrail.cap + 9)"))
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(RecentTrail.shelf(from: []).isEmpty)
    }
}
