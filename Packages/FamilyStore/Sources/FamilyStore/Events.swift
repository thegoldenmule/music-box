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

/// One search, debounced to the term the kid settled on rather than every
/// keystroke.
public struct SearchEvent: Hashable, Sendable {
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
public struct PlayEvent: Hashable, Sendable {
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
public struct BlockEvent: Hashable, Sendable {
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
