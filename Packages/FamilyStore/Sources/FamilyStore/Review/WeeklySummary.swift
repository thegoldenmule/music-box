import Foundation
import PolicyEngine

/// A week, derived from live events until the retention sweep takes them,
/// then persisted as this exact form. `Codable` with frozen `CodingKeys`
/// since old builds must still read it, and deterministic — sorted,
/// tie-broken on identity — so two devices summarising one week write
/// identical bytes under one record name, which is what lets the sweep run
/// with no owner and no lease.
public struct WeeklySummary: Sendable, Codable, Equatable {
    public struct Tally: Sendable, Hashable, Identifiable, Codable {
        public let id: String
        public let name: String
        public let seconds: Int
        public let plays: Int

        enum CodingKeys: String, CodingKey {
            case id
            case name = "n"
            case seconds = "sec"
            case plays = "p"
        }
    }

    enum CodingKeys: String, CodingKey {
        case interval = "iv"
        case topArtists = "ta"
        case topSongs = "ts"
        case firstTimeHeard = "fth"
        case blocksByArtist = "bba"
        case totalListeningSeconds = "tls"
        case searches = "s"
        case reachedBlockCount = "rbc"
    }

    public let interval: DateInterval

    /// By listening time, not play count — one album all afternoon still counts.
    public let topArtists: [Tally]

    /// By play count, because a song replayed is the signal for a song.
    public let topSongs: [Tally]

    /// First plays this week; needs an earlier window to know what came before.
    public let firstTimeHeard: [Tally]

    public let blocksByArtist: [BlockGroup]
    public let totalListeningSeconds: Int

    /// Verbatim terms, not a count — sweeping saves storage, never sensitivity.
    public let searches: [SearchEvent]

    /// Kept so every existing reader still compiles and reads the same number.
    public var searchCount: Int { searches.count }

    /// Reached blocks only; the unseen count is per-group, not a headline number.
    public let reachedBlockCount: Int
}

extension WeeklySummary {
    /// Rows per list — a summary is read in one go, not scrolled like a leaderboard.
    public static let topCount = 5

    /// `previouslyHeard: nil` yields an empty list, never a false first-time claim.
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
            // Unresolved lineage still counts toward the total, just not by artist.
            if let artistID = play.artistID {
                artistSeconds[artistID, default: 0] += play.secondsPlayed
                artistPlays[artistID, default: 0] += 1
                // No artist name on a play row; an honest ID beats a guessed name.
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
            // Tie-break on `id`: without it, equal artists sort by device-local order.
            .sorted { ($0.seconds, $0.plays, $1.id) > ($1.seconds, $1.plays, $0.id) }
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
            .sorted { ($0.plays, $0.seconds, $1.id) > ($1.plays, $1.seconds, $0.id) }
            .prefix(topCount)

        let firstTime: [Tally]
        if let previouslyHeard {
            firstTime =
                songPlays.keys
                .filter { !previouslyHeard.contains($0) }
                .sorted {
                    (firstPlayAt[$0] ?? .distantPast, $0.rawValue)
                        < (firstPlayAt[$1] ?? .distantPast, $1.rawValue)
                }
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
            blocksByArtist: BlockGroup.group(window.blocks).sorted { $0.id < $1.id },
            totalListeningSeconds: window.totalListeningSeconds,
            // Sorted like the tallies: this payload is compared byte for byte.
            searches: window.searches.sorted { ($0.at, $0.term) < ($1.at, $1.term) },
            reachedBlockCount: window.blocks.filter { $0.event.reach == .reached }.count
        )
    }

    /// Sorted keys, so identical events always produce identical bytes.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
