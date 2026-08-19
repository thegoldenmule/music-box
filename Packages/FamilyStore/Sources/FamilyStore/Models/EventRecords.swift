import Foundation
import PolicyEngine
import SwiftData

// A v1 column left out is absent forever — nothing backfills an unwritten fact.

// MARK: The two sync columns

// `originatingDeviceID` names the device; `exportedAt` gates the sweep.

/// The write model; ``RecentTrail`` projects it so a sweep can't empty the shelf.
@Model
public final class VisitEventRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var at: Date = Date.distantPast

    public private(set) var catalogID: String = ""

    /// Part of the identity — MusicKit ids are unique only within a kind.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    public private(set) var displayName: String = ""
    public private(set) var artworkURL: URL?

    /// Lineage as of the visit; `nil` when it never resolved (see `VisitEvent`).
    public private(set) var albumID: String?
    public private(set) var artistID: String?

    public private(set) var rating: String = StoredRating.Name.unknown
    public private(set) var manner: String = VisitManner.opened.rawValue

    /// See *The two sync columns* at the top of this file.
    public private(set) var originatingDeviceID: UUID?
    public private(set) var exportedAt: Date?

    /// Stamps as carried; never touches `kid` — export is our bookkeeping, not theirs.
    public func markExported(at: Date = .now) { exportedAt = at }

    public var kid: Kid?

    public init(id: UUID = UUID(), event: VisitEvent, originatingDeviceID: UUID? = nil) {
        self.id = id
        self.originatingDeviceID = originatingDeviceID
        self.at = event.at
        self.catalogID = event.itemID.rawValue
        self.itemKind = event.itemID.kind.rawValue
        self.displayName = event.displayName
        self.artworkURL = event.artworkURL
        self.albumID = event.albumID?.rawValue
        self.artistID = event.artistID?.rawValue
        self.rating = event.rating.stored
        self.manner = event.manner.rawValue
    }

    /// The typed event, or `nil` if the kind or manner columns do not read back.
    public var event: VisitEvent? {
        guard
            let itemKind = ItemKind(rawValue: itemKind),
            let manner = VisitManner(rawValue: manner)
        else { return nil }
        return VisitEvent(
            itemID: CatalogID(itemKind, catalogID),
            displayName: displayName,
            artworkURL: artworkURL,
            albumID: albumID.map { CatalogID(.album, $0) },
            artistID: artistID.map { CatalogID(.artist, $0) },
            rating: StoredRating(stored: rating),
            manner: manner,
            at: at
        )
    }
}

/// One search — the term the kid settled on, not every keystroke.
@Model
public final class SearchEventRecord {
    public private(set) var id: UUID = UUID()

    /// Device time, which a kid can change — weekly bucketing is approximate.
    public private(set) var at: Date = Date.distantPast
    public private(set) var term: String = ""
    public private(set) var resultCount: Int = 0
    public private(set) var blockedCount: Int = 0

    /// Not "nothing matched" — the over-fetch loop hit its cap while still short.
    public private(set) var gaveUpEarly: Bool = false

    /// See *The two sync columns* at the top of this file.
    public private(set) var originatingDeviceID: UUID?
    public private(set) var exportedAt: Date?

    /// Stamps as carried; never touches `kid` — export is our bookkeeping, not theirs.
    public func markExported(at: Date = .now) { exportedAt = at }

    public var kid: Kid?

    public init(id: UUID = UUID(), event: SearchEvent, originatingDeviceID: UUID? = nil) {
        self.id = id
        self.originatingDeviceID = originatingDeviceID
        self.at = event.at
        self.term = event.term
        self.resultCount = event.resultCount
        self.blockedCount = event.blockedCount
        self.gaveUpEarly = event.gaveUpEarly
    }

    public var event: SearchEvent {
        SearchEvent(
            term: term,
            at: at,
            resultCount: resultCount,
            blockedCount: blockedCount,
            gaveUpEarly: gaveUpEarly
        )
    }
}

/// One play, written on stop.
@Model
public final class PlayEventRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var at: Date = Date.distantPast

    /// Kinds are implied by the column: song, album, artist respectively.
    public private(set) var songID: String = ""

    /// `nil` unresolved rows still count toward totals, just ungroupable.
    public private(set) var albumID: String?
    public private(set) var artistID: String?

    /// Captured at play time; survives delisting.
    public private(set) var displayName: String = ""

    /// Recorded so the report can re-judge rows; default `unknown` means unrated.
    public private(set) var rating: String = StoredRating.Name.unknown

    /// Never below `EventLog.minimumPlaySeconds` — a mis-tap isn't a listen.
    public private(set) var secondsPlayed: Int = 0

    public private(set) var origin: String = PlaybackOrigin.Name.home
    public private(set) var originTerm: String?
    public private(set) var originKind: String?
    public private(set) var originID: String?

    /// See *The two sync columns* at the top of this file.
    public private(set) var originatingDeviceID: UUID?
    public private(set) var exportedAt: Date?

    /// Stamps as carried; never touches `kid` — export is our bookkeeping, not theirs.
    public func markExported(at: Date = .now) { exportedAt = at }

    public var kid: Kid?

    public init(id: UUID = UUID(), event: PlayEvent, originatingDeviceID: UUID? = nil) {
        let origin = event.origin.stored
        self.id = id
        self.originatingDeviceID = originatingDeviceID
        self.at = event.at
        self.songID = event.songID.rawValue
        self.albumID = event.albumID?.rawValue
        self.artistID = event.artistID?.rawValue
        self.displayName = event.displayName
        self.rating = event.rating.stored
        self.secondsPlayed = event.secondsPlayed
        self.origin = origin.name
        self.originTerm = origin.term
        self.originKind = origin.kind
        self.originID = origin.id
    }

    /// Internal — the only way to build a row this version can't read.
    init(
        id: UUID = UUID(),
        songID: String,
        rawOrigin: String,
        originTerm: String? = nil,
        at: Date = .now
    ) {
        self.id = id
        self.at = at
        self.songID = songID
        self.displayName = "A Song"
        self.secondsPlayed = 30
        self.origin = rawOrigin
        self.originTerm = originTerm
    }

    /// The typed event, or `nil` if the origin columns do not read back.
    public var event: PlayEvent? {
        guard
            let origin = PlaybackOrigin(
                stored: StoredOrigin(
                    name: origin,
                    term: originTerm,
                    kind: originKind,
                    id: originID
                )
            )
        else { return nil }
        return PlayEvent(
            songID: CatalogID(.song, songID),
            albumID: albumID.map { CatalogID(.album, $0) },
            artistID: artistID.map { CatalogID(.artist, $0) },
            displayName: displayName,
            rating: StoredRating(stored: rating),
            at: at,
            secondsPlayed: secondsPlayed,
            origin: origin
        )
    }
}

/// One block — including results filtered out of a search the kid never saw.
@Model
public final class BlockEventRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var at: Date = Date.distantPast

    public private(set) var itemID: String = ""

    /// Not in the spec's schema — an id without its kind is ambiguous across kinds.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    public private(set) var displayName: String = ""

    /// `nil` unresolved; the report shows the row under its own name, not dropped.
    public private(set) var artistID: String?

    /// What the catalog said when judged. See ``PlayEvent/rating``.
    public private(set) var rating: String = StoredRating.Name.unknown

    /// Whether the kid saw this or it was filtered first — see ``BlockReach``.
    public private(set) var reach: String = BlockReach.unseen.rawValue

    /// Includes `restrictedOutsideApp`, not one of our rules. See ``BlockReason``.
    public private(set) var reason: String = BlockReason.Name.notOnAllowList

    /// Which entry matched; two columns because kind is part of the identity.
    public private(set) var deniedByKind: String?
    public private(set) var deniedByID: String?

    public private(set) var origin: String = PlaybackOrigin.Name.home
    public private(set) var originTerm: String?
    public private(set) var originKind: String?
    public private(set) var originID: String?

    /// See *The two sync columns* at the top of this file.
    public private(set) var originatingDeviceID: UUID?
    public private(set) var exportedAt: Date?

    /// Stamps as carried; never touches `kid` — export is our bookkeeping, not theirs.
    public func markExported(at: Date = .now) { exportedAt = at }

    public var kid: Kid?

    public init(id: UUID = UUID(), event: BlockEvent, originatingDeviceID: UUID? = nil) {
        let origin = event.origin.stored
        let reason = event.reason.stored
        self.id = id
        self.originatingDeviceID = originatingDeviceID
        self.at = event.at
        self.itemID = event.itemID.rawValue
        self.itemKind = event.itemID.kind.rawValue
        self.displayName = event.displayName
        self.artistID = event.artistID?.rawValue
        self.rating = event.rating.stored
        self.reach = event.reach.rawValue
        self.reason = reason.name
        self.deniedByKind = reason.deniedByKind
        self.deniedByID = reason.deniedByID
        self.origin = origin.name
        self.originTerm = origin.term
        self.originKind = origin.kind
        self.originID = origin.id
    }

    /// Builds a row from stored strings — see the `PlayEventRecord` counterpart.
    init(
        id: UUID = UUID(),
        itemID: String,
        rawItemKind: String = ItemKind.song.rawValue,
        rawReach: String = BlockReach.unseen.rawValue,
        rawReason: String = BlockReason.Name.notOnAllowList,
        rawOrigin: String = PlaybackOrigin.Name.home,
        at: Date = .now
    ) {
        self.id = id
        self.at = at
        self.itemID = itemID
        self.itemKind = rawItemKind
        self.displayName = "Something"
        self.reach = rawReach
        self.reason = rawReason
        self.origin = rawOrigin
    }

    /// The typed event, or `nil` if the reason or origin columns don't read back.
    public var event: BlockEvent? {
        guard
            let itemKind = ItemKind(rawValue: itemKind),
            let reach = BlockReach(rawValue: reach),
            let reason = BlockReason(
                stored: StoredReason(
                    name: reason,
                    deniedByKind: deniedByKind,
                    deniedByID: deniedByID
                )
            ),
            let origin = PlaybackOrigin(
                stored: StoredOrigin(
                    name: origin,
                    term: originTerm,
                    kind: originKind,
                    id: originID
                )
            )
        else { return nil }
        return BlockEvent(
            itemID: CatalogID(itemKind, itemID),
            displayName: displayName,
            artistID: artistID.map { CatalogID(.artist, $0) },
            rating: StoredRating(stored: rating),
            at: at,
            reach: reach,
            reason: reason,
            origin: origin
        )
    }
}

/// Lets the exporter run once; a table missing `exportedAt` fails to conform.
public protocol ExportableEvent: AnyObject {
    var id: UUID { get }
    var at: Date { get }
    var exportedAt: Date? { get }
    var originatingDeviceID: UUID? { get }

    /// Stamped once handed to a segment; the sweep must not delete an unexported row.
    func markExported(at: Date)
}

extension VisitEventRecord: ExportableEvent {}
extension SearchEventRecord: ExportableEvent {}
extension PlayEventRecord: ExportableEvent {}
extension BlockEventRecord: ExportableEvent {}
