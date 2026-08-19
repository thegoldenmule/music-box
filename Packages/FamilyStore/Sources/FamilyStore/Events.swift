import Foundation
import PolicyEngine

/// No `origin`: the trail's previous entry says more than a coarse guess would.
public struct VisitEvent: Hashable, Sendable, Codable {
    /// Frozen, short wire names — read back months later by builds that vary.
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

    /// `nil` lineage isn't anyone's descendant — fails toward showing more.
    public let albumID: CatalogID?
    public let artistID: CatalogID?

    /// What the catalog said then; the report re-judges rows against today's policy.
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

/// One search, debounced to the term the kid settled on, not every keystroke.
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

    /// Not "nothing matched" — zero results and giving up are different states.
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

    /// `nil` unresolved rows still count toward totals, just not by album/artist.
    public let albumID: CatalogID?
    public let artistID: CatalogID?

    /// Captured at play time, so a delisted song still reads as a name.
    public let displayName: String

    /// Kept so the report can re-judge rows; distinguishes "unrated" from "unknown".
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

/// Blocks are the log's valuable half — kept with reason, never dropped.
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

    /// What the catalog said when judged; tells if an allow-since was a rating call.
    public let rating: StoredRating
    public let at: Date

    /// The one block field that is about the kid rather than about the item.
    public let reach: BlockReach

    /// Captured at judgement time — the policy behind it may since have changed.
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
