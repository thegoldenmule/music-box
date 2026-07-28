import Foundation
import PolicyEngine
import SwiftData

// Three event tables. Between them they carry every field v1 can record,
// including the ones nothing reads yet: a column absent at v1 is absent for
// that whole period forever, because no later release can backfill a fact
// nobody wrote down.

/// One arrival: a song pressed play on, or a container opened.
///
/// The write model. What the Recent shelf actually draws is a *projection* over
/// these — see ``RecentTrail`` — which is why this table can be swept by
/// retention without emptying a kid's home screen.
@Model
public final class VisitEventRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var at: Date = Date.distantPast

    public private(set) var catalogID: String = ""

    /// Part of the identity, not decoration: a visit lands on any of the four
    /// kinds and MusicKit identifiers are only unique within a type.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    public private(set) var displayName: String = ""
    public private(set) var artworkURL: URL?

    /// Lineage as it stood at the moment of the visit. `nil` when it never
    /// resolved; see ``VisitEvent``.
    public private(set) var albumID: String?
    public private(set) var artistID: String?

    public private(set) var rating: String = StoredRating.Name.unknown
    public private(set) var manner: String = VisitManner.opened.rawValue

    public var kid: Kid?

    public init(id: UUID = UUID(), event: VisitEvent) {
        self.id = id
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

    /// Device time, which a kid can change. Weekly bucketing is approximate.
    public private(set) var at: Date = Date.distantPast
    public private(set) var term: String = ""
    public private(set) var resultCount: Int = 0
    public private(set) var blockedCount: Int = 0

    /// We stopped looking. A row with `resultCount == 0` and this set did not
    /// find nothing — the over-fetch loop hit its cap while still short.
    public private(set) var gaveUpEarly: Bool = false

    public var kid: Kid?

    public init(id: UUID = UUID(), event: SearchEvent) {
        self.id = id
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

    /// `nil` when lineage never resolved. Such rows count toward totals but
    /// cannot be grouped.
    public private(set) var albumID: String?
    public private(set) var artistID: String?

    /// Captured at play time; survives delisting.
    public private(set) var displayName: String = ""

    /// What the catalog said when this played. See ``PlayEvent/rating`` — the
    /// parent's report re-judges these rows and cannot do it without this.
    ///
    /// The schema default is ``StoredRating/unknown``, which is the honest one:
    /// a row that somehow fell back to it is a row nobody rated, and that is
    /// exactly what `unknown` means.
    public private(set) var rating: String = StoredRating.Name.unknown

    /// Never below ``EventLog/minimumPlaySeconds``. A mis-tap is not a listen,
    /// and the filter is applied before the row is made.
    public private(set) var secondsPlayed: Int = 0

    public private(set) var origin: String = PlaybackOrigin.Name.home
    public private(set) var originTerm: String?
    public private(set) var originKind: String?
    public private(set) var originID: String?

    public var kid: Kid?

    public init(id: UUID = UUID(), event: PlayEvent) {
        let origin = event.origin.stored
        self.id = id
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

    /// Builds a row straight from stored strings, bypassing the typed enums.
    ///
    /// Internal, and the only way to produce a row this version cannot read —
    /// which is what the `unreadable` count in ``ReviewWindow`` has to be tested
    /// against. Until the parent's report existed, nothing had ever exercised
    /// the `nil` return below.
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

    /// The blocked item's kind. Not in the spec's schema, which stored the
    /// identifier bare — but a block can land on any of the four kinds, and an
    /// identifier without its kind is ambiguous across them.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    public private(set) var displayName: String = ""

    /// `nil` when lineage never resolved. The report shows such a row under its
    /// own name rather than dropping it.
    public private(set) var artistID: String?

    /// What the catalog said when this was judged. See ``PlayEvent/rating``.
    public private(set) var rating: String = StoredRating.Name.unknown

    /// Whether the kid saw this or whether we filtered it before they could.
    ///
    /// Not in the spec's original schema, which stored neither — and the two
    /// paths that write these rows are otherwise indistinguishable. See
    /// ``BlockReach``, which is also the one column here that is about the child
    /// rather than about the item or the rule.
    ///
    /// The schema default is `unseen`, the overwhelmingly more common case; no
    /// real row falls back to it, because the initializer always supplies one.
    public private(set) var reach: String = BlockReach.unseen.rawValue

    /// Includes `restrictedOutsideApp`, which is *not* one of our rules. See
    /// ``BlockReason``.
    public private(set) var reason: String = BlockReason.Name.notOnAllowList

    /// Which entry matched, for `deniedByParent`. Two columns, because the kind
    /// is part of the identity.
    public private(set) var deniedByKind: String?
    public private(set) var deniedByID: String?

    public private(set) var origin: String = PlaybackOrigin.Name.home
    public private(set) var originTerm: String?
    public private(set) var originKind: String?
    public private(set) var originID: String?

    public var kid: Kid?

    public init(id: UUID = UUID(), event: BlockEvent) {
        let origin = event.origin.stored
        let reason = event.reason.stored
        self.id = id
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

    /// Builds a row straight from stored strings. See
    /// ``PlayEventRecord/init(id:songID:rawOrigin:originTerm:at:)``.
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

    /// The typed event, or `nil` if the reason or origin columns do not read
    /// back.
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
