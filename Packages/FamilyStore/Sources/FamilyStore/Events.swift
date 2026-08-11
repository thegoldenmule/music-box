import Foundation
import PolicyEngine

/// The three things worth recording, as values.
///
/// These cross an actor boundary on their way to the store — ``EventLog`` runs
/// off the caller's thread — so they are `Sendable` structs rather than the
/// `@Model` classes they become. The caller never touches a model object.
///
/// Every timestamp is supplied, never taken from a hidden clock. It is device
/// time either way, which a kid can change, so weekly bucketing is approximate
/// and a report is not forensic.

/// The kid arrived at something.
///
/// One fact covering four kinds: they pressed play on a song, or they opened an
/// album, an artist, a playlist. It is one event rather than four because the
/// trail that feeds the Recent shelf has to compare them *to each other* — an
/// album supersedes its artist, a song supersedes its album — and a comparison
/// across four tables is four times the work for no extra truth.
///
/// **Distinct from ``PlayEvent``, which is written on stop.** Duration is the
/// signal the parent's report wants, so a play is recorded when it ends and a
/// mis-tap under five seconds is never recorded at all. Neither of those is what
/// a Recent shelf means by recent: a kid who presses play wants to see it there
/// now, not when the song finishes. Started and listened-for-N-seconds are two
/// facts and both are worth having.
///
/// **No `origin`, deliberately** — the one event without one. A visit is
/// recorded where a container push lands, and `TileCell` pushes a bare
/// `CatalogItem` through `NavigationLink(value:)`, dropping the origin on the
/// way. The alternative to a guess is better than the guess: the trail's
/// *previous entry* is where the kid came from, which is strictly more than
/// `browse(id)` carries. If something ever genuinely needs the coarse origin,
/// thread a route value through `TileCell` rather than inventing a column here.
public struct VisitEvent: Hashable, Sendable, Codable {
    /// **Frozen, and short.** These names are the wire format of an activity
    /// segment — bytes read back out of a parent's history months later, possibly
    /// by a build that did not write them — so renaming a property must not change
    /// them. Short because the four event tables are the great majority of this
    /// store's write volume. Same rule on all four types below.
    enum CodingKeys: String, CodingKey {
        case itemID = "id"
        case displayName = "n"
        case artworkURL = "aw"
        case albumID = "alb"
        case artistID = "art"
        case rating = "rat"
        case manner = "man"
        case at
    }

    public let itemID: CatalogID

    /// Captured now, so a delisted album still reads as a name.
    public let displayName: String

    /// A reference. Artwork bytes are never copied into our storage.
    public let artworkURL: URL?

    /// Lineage, and the whole basis of the walk: a song belongs to an album and
    /// an artist, an album to an artist. `nil` when it never resolved — and an
    /// entry with unknown lineage is deliberately **not** treated as anyone's
    /// descendant, so the container it came from stays on the shelf beside it.
    /// That fails toward showing more, which on a shelf costs nothing.
    public let albumID: CatalogID?
    public let artistID: CatalogID?

    /// What the catalog said when they got here. See ``PlayEvent/rating`` —
    /// same field, same reason: the parent's report re-judges old rows against
    /// today's policy, and the rating is what decides most of them.
    public let rating: StoredRating

    /// Opened, or played. The shelf does not care; a parent does.
    public let manner: VisitManner

    public let at: Date

    public init(
        itemID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        albumID: CatalogID? = nil,
        artistID: CatalogID? = nil,
        rating: StoredRating = .unknown,
        manner: VisitManner,
        at: Date = .now
    ) {
        self.itemID = itemID
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.albumID = albumID
        self.artistID = artistID
        self.rating = rating
        self.manner = manner
        self.at = at
    }
}

/// One search, debounced to the term the kid settled on rather than every
/// keystroke.
public struct SearchEvent: Hashable, Sendable, Codable {
    enum CodingKeys: String, CodingKey {
        case term = "t"
        case at
        case resultCount = "rc"
        case blockedCount = "bc"
        case gaveUpEarly = "gu"
    }

    public let term: String
    public let at: Date
    public let resultCount: Int
    public let blockedCount: Int

    /// We stopped looking. **Not** "nothing matched" — a search logged with zero
    /// results and this set did not find nothing, it gave up.
    public let gaveUpEarly: Bool

    public init(
        term: String,
        at: Date = .now,
        resultCount: Int,
        blockedCount: Int,
        gaveUpEarly: Bool
    ) {
        self.term = term
        self.at = at
        self.resultCount = resultCount
        self.blockedCount = blockedCount
        self.gaveUpEarly = gaveUpEarly
    }
}

/// One play, written on stop — duration is the signal.
public struct PlayEvent: Hashable, Sendable, Codable {
    enum CodingKeys: String, CodingKey {
        case songID = "id"
        case albumID = "alb"
        case artistID = "art"
        case displayName = "n"
        case rating = "rat"
        case at
        case secondsPlayed = "sec"
        case origin = "org"
    }

    public let songID: CatalogID

    /// `nil` when lineage never resolved. Such rows count toward totals but
    /// cannot be grouped by album or artist.
    public let albumID: CatalogID?
    public let artistID: CatalogID?

    /// Captured at play time, so a delisted song still reads as a name.
    public let displayName: String

    /// What the catalog said about this song when it played.
    ///
    /// Recorded because the parent's report re-judges old rows against today's
    /// policy, and **the rating is the input that decides most of them.** A row
    /// without it, handed to a `denyPlusAuto` engine, comes back
    /// `blocked(.unrated)` for everything — a report claiming a kid can no
    /// longer play the whole of last week.
    ///
    /// A ``StoredRating`` rather than a bare optional so that "the catalog gave
    /// no rating" stays distinguishable from "nobody wrote it down". `nil` here
    /// is not `.clean` and is not `.unknown` either.
    public let rating: StoredRating
    public let at: Date
    public let secondsPlayed: Int
    public let origin: PlaybackOrigin

    public init(
        songID: CatalogID,
        albumID: CatalogID? = nil,
        artistID: CatalogID? = nil,
        displayName: String,
        rating: StoredRating = .unknown,
        at: Date = .now,
        secondsPlayed: Int,
        origin: PlaybackOrigin
    ) {
        self.songID = songID
        self.albumID = albumID
        self.artistID = artistID
        self.displayName = displayName
        self.rating = rating
        self.at = at
        self.secondsPlayed = secondsPlayed
        self.origin = origin
    }
}

/// One block, including ones filtered out of a search the kid never saw.
///
/// Blocks are the valuable half of the log: they are how a parent learns what
/// their kid is curious about. Kept with their reason, never dropped.
public struct BlockEvent: Hashable, Sendable, Codable {
    enum CodingKeys: String, CodingKey {
        case itemID = "id"
        case displayName = "n"
        case artistID = "art"
        case rating = "rat"
        case at
        case reach = "rch"
        case reason = "rsn"
        case origin = "org"
    }

    public let itemID: CatalogID
    public let displayName: String

    /// `nil` when lineage never resolved.
    public let artistID: CatalogID?

    /// What the catalog said about this item when it was judged. See
    /// ``PlayEvent/rating`` — same field, same reason, and here it also lets a
    /// report say whether a block a parent has since allowed was about a rating
    /// or about one of their own rules.
    public let rating: StoredRating
    public let at: Date

    /// Whether the kid ever saw this. The one field on a block that is about
    /// them rather than about the item.
    public let reach: BlockReach

    /// Captured at judgement time, because the policy that produced it may have
    /// changed by the time anyone reads the report.
    public let reason: BlockReason
    public let origin: PlaybackOrigin

    public init(
        itemID: CatalogID,
        displayName: String,
        artistID: CatalogID? = nil,
        rating: StoredRating = .unknown,
        at: Date = .now,
        reach: BlockReach,
        reason: BlockReason,
        origin: PlaybackOrigin
    ) {
        self.itemID = itemID
        self.displayName = displayName
        self.artistID = artistID
        self.rating = rating
        self.at = at
        self.reach = reach
        self.reason = reason
        self.origin = origin
    }
}
