import Foundation
import PolicyEngine

/// A week, as a parent reads it.
///
/// **Derived on read while the events exist**, so there is nothing to keep in
/// sync and no way for a summary to disagree with the rows under it. It is
/// persisted only once the retention sweep has taken those rows away — see
/// ``WeeklySummaryRecord``.
public struct WeeklySummary: Sendable {
    public struct Tally: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let seconds: Int
        public let plays: Int
    }

    public let interval: DateInterval

    /// By listening time, not by play count. A kid who leaves one album on all
    /// afternoon was into that album, however few taps it took.
    public let topArtists: [Tally]

    /// By play count, because a song replayed is the signal for a song.
    public let topSongs: [Tally]

    /// Songs with no play before this week started. Requires knowing what came
    /// before, which is why it is computed with a second, earlier window rather
    /// than from this one alone.
    public let firstTimeHeard: [Tally]

    public let blocksByArtist: [BlockGroup]
    public let totalListeningSeconds: Int
    public let searchCount: Int

    /// Blocks the kid actually reached for. The number worth putting next to
    /// the others; the unseen count is a fact about our filter and lives inside
    /// each group.
    public let reachedBlockCount: Int
}

extension WeeklySummary {
    /// How many rows each list keeps. A summary is a thing a parent reads in one
    /// go, not a leaderboard.
    public static let topCount = 5

    /// Builds a summary from a window.
    ///
    /// - Parameter previouslyHeard: song identifiers played before this window
    ///   began. Empty means everything reads as first-time-heard, which is true
    ///   of a kid's first week and a lie in any other, so a caller that cannot
    ///   answer should pass ``nil`` and get an empty list instead of a wrong
    ///   one.
    public static func of(
        _ window: ReviewWindow,
        previouslyHeard: Set<CatalogID>?
    ) -> WeeklySummary {
        let plays = window.plays

        var artistSeconds: [CatalogID: Int] = [:]
        var artistPlays: [CatalogID: Int] = [:]
        var artistNames: [CatalogID: String] = [:]
        var songSeconds: [CatalogID: Int] = [:]
        var songPlays: [CatalogID: Int] = [:]
        var songNames: [CatalogID: String] = [:]
        var firstPlayAt: [CatalogID: Date] = [:]

        for play in plays {
            // A row whose lineage never resolved counts toward the total and
            // cannot be grouped by artist. It is not dropped; it simply does not
            // appear in a list it has no key for.
            if let artistID = play.artistID {
                artistSeconds[artistID, default: 0] += play.secondsPlayed
                artistPlays[artistID, default: 0] += 1
                // The artist's name is not on a play row — only the song's is.
                // Better an honest identifier than the wrong name; a screen with
                // the catalog to hand can improve on it.
                artistNames[artistID] = artistNames[artistID] ?? artistID.rawValue
            }
            songSeconds[play.songID, default: 0] += play.secondsPlayed
            songPlays[play.songID, default: 0] += 1
            songNames[play.songID] = play.displayName
            firstPlayAt[play.songID] = min(firstPlayAt[play.songID] ?? play.at, play.at)
        }

        let topArtists = artistSeconds
            .map {
                Tally(
                    id: $0.key.rawValue,
                    name: artistNames[$0.key] ?? $0.key.rawValue,
                    seconds: $0.value,
                    plays: artistPlays[$0.key] ?? 0
                )
            }
            .sorted { ($0.seconds, $0.plays) > ($1.seconds, $1.plays) }
            .prefix(topCount)

        let songTallies = songPlays.map {
            Tally(
                id: $0.key.rawValue,
                name: songNames[$0.key] ?? $0.key.rawValue,
                seconds: songSeconds[$0.key] ?? 0,
                plays: $0.value
            )
        }

        let topSongs =
            songTallies
            .sorted { ($0.plays, $0.seconds) > ($1.plays, $1.seconds) }
            .prefix(topCount)

        let firstTime: [Tally]
        if let previouslyHeard {
            firstTime =
                songPlays.keys
                .filter { !previouslyHeard.contains($0) }
                .sorted { (firstPlayAt[$0] ?? .distantPast) < (firstPlayAt[$1] ?? .distantPast) }
                .prefix(topCount)
                .map { id in
                    Tally(
                        id: id.rawValue,
                        name: songNames[id] ?? id.rawValue,
                        seconds: songSeconds[id] ?? 0,
                        plays: songPlays[id] ?? 0
                    )
                }
        } else {
            firstTime = []
        }

        return WeeklySummary(
            interval: window.interval,
            topArtists: Array(topArtists),
            topSongs: Array(topSongs),
            firstTimeHeard: firstTime,
            blocksByArtist: BlockGroup.group(window.blocks),
            totalListeningSeconds: window.totalListeningSeconds,
            searchCount: window.searches.count,
            reachedBlockCount: window.blocks.filter { $0.event.reach == .reached }.count
        )
    }
}
