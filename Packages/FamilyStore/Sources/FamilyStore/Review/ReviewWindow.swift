import Foundation
import PolicyEngine

/// Everything the store knows about one kid over one interval, unfiltered.
///
/// **Nothing here has been through the policy engine.** Every other read in the
/// app drops what comes back blocked; this one keeps all of it, because a denied
/// item is what the parent's screen exists to show. The engine is applied later
/// and only to annotate — see ``ReviewAnnotator``.
///
/// Values, not `@Model` objects. Built inside ``ReviewReader``'s own context and
/// handed out as `Sendable` structs, which is the same contract ``EventLog``
/// keeps in the other direction.
public struct ReviewWindow: Sendable {
    public let kidID: UUID

    /// What this window covers, in device time. Always bounded: an open-ended
    /// window is a fetch with no limit over the largest table in the store.
    public let interval: DateInterval

    public let plays: [PlayEvent]
    public let searches: [SearchEvent]
    public let blocks: [ReviewedBlock]

    /// Where they went: containers opened, and songs at the moment play
    /// started. The Recent shelf is a projection over these, but the parent's
    /// report reads them raw — a shelf is a summary and this is the record.
    public let visits: [VisitEvent]

    /// Rows whose stored columns did not read back into a typed event.
    ///
    /// A count rather than the rows, because there is nothing to show — but a
    /// silent zero and a silent forty look identical on screen, and one of them
    /// is a bug in us. These are also the first exercise ``PlaybackOrigin`` and
    /// ``BlockReason`` round-tripping has ever had.
    public let unreadable: Int

    /// When this was built. The kid may be playing right now, and the song
    /// playing has no row yet — a play is written on stop.
    public let builtAt: Date

    public let coverage: Coverage

    public init(
        kidID: UUID,
        interval: DateInterval,
        plays: [PlayEvent],
        searches: [SearchEvent],
        blocks: [ReviewedBlock],
        visits: [VisitEvent] = [],
        unreadable: Int,
        builtAt: Date,
        coverage: Coverage
    ) {
        self.kidID = kidID
        self.interval = interval
        self.plays = plays
        self.searches = searches
        self.blocks = blocks
        self.visits = visits
        self.unreadable = unreadable
        self.builtAt = builtAt
        self.coverage = coverage
    }

    public var isEmpty: Bool {
        plays.isEmpty && searches.isEmpty && blocks.isEmpty && visits.isEmpty
    }

    public var totalListeningSeconds: Int { plays.reduce(0) { $0 + $1.secondsPlayed } }
}

/// What a window can and cannot answer, because retention ate part of it.
///
/// Exists before the sweep that fills it does, and deliberately. An empty list
/// means "nothing happened", and a swept week must not be able to say that: a
/// parent who reads a year of history and later finds it gone has experienced a
/// deletion, not a policy. Added afterwards, there would be no way to tell which
/// weeks had been swept.
public enum Coverage: Sendable, Hashable {
    /// Raw events cover the whole interval.
    case complete

    /// Raw events exist only at or after this date. Before it there are
    /// summaries and nothing else.
    case summarisedBefore(Date)
}

/// A block with the entry that produced it resolved to something a parent
/// recognises.
public struct ReviewedBlock: Sendable {
    public let event: BlockEvent

    /// For ``BlockReason/deniedByParent(_:)``: that entry as it stands *today*.
    ///
    /// `nil` once the entry has been removed — which is the common case straight
    /// after approve-from-report. The block still happened and keeps its stored
    /// reason; the rule no longer exists. Never re-derived from whatever rule
    /// *would* catch it now, because that invents a fact.
    public let deniedBy: PolicyEntrySnapshot?

    public init(event: BlockEvent, deniedBy: PolicyEntrySnapshot? = nil) {
        self.event = event
        self.deniedBy = deniedBy
    }
}

public struct PolicyEntrySnapshot: Sendable, Hashable {
    public let id: CatalogID
    public let displayName: String
    public let kind: PolicyEntry.Kind

    public init(id: CatalogID, displayName: String, kind: PolicyEntry.Kind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

// MARK: - Grouping

/// Blocks collapsed to the unit a parent actually reads.
///
/// By artist, because that is the question they are asking — *is my kid into
/// this band?* — and because the artist is what approve-from-report widens to.
public struct BlockGroup: Sendable, Identifiable {
    /// `nil` when no row in the group ever resolved an artist. Such a group is
    /// keyed by name instead and cannot be widened to an artist.
    public let artistID: CatalogID?
    public let displayName: String

    /// **Split, never summed.** `unseen` is usually two orders of magnitude
    /// larger and is a fact about our filter rather than about the child.
    public let reached: Int
    public let unseen: Int

    /// More than one when different rules caught different tracks.
    public let reasons: Set<BlockReason>

    public let firstAt: Date
    public let latestAt: Date

    /// A row the kid reached for when the group has one, otherwise the most
    /// recent. It carries the origin, which is what turns a group into a
    /// sentence: *while searching for monster*.
    public let sample: BlockEvent

    public var id: String { artistID.map(\.rawValue) ?? "name:\(displayName)" }

    public var total: Int { reached + unseen }
}

extension BlockGroup {
    /// Groups a window's blocks, most-reached-for first.
    ///
    /// The ordering is the whole point: what the kid went for sits above what we
    /// filtered on their behalf. Sorting by volume instead would put whichever
    /// artist happens to have the most explicit tracks in the catalog at the
    /// top, which is a fact about that discography and nothing to do with this
    /// family.
    public static func group(_ blocks: [ReviewedBlock]) -> [BlockGroup] {
        // Keyed by artist where there is one, by display name where there is
        // not — a row whose lineage never resolved is shown under its own name
        // rather than dropped.
        var order: [String] = []
        var buckets: [String: [BlockEvent]] = [:]

        for block in blocks {
            let event = block.event
            let key = event.artistID.map(\.rawValue) ?? "name:\(event.displayName)"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(event)
        }

        let groups = order.compactMap { key -> BlockGroup? in
            guard let events = buckets[key], let newest = events.max(by: { $0.at < $1.at })
            else { return nil }
            let reached = events.filter { $0.reach == .reached }

            return BlockGroup(
                artistID: events.compactMap(\.artistID).first,
                // The artist's own name when the artist itself was blocked;
                // otherwise the newest track's, which is the best label a row
                // that only stores an artist *identifier* can offer. A screen
                // with the catalog to hand can do better and is welcome to.
                displayName: name(of: events),
                reached: reached.count,
                unseen: events.count - reached.count,
                reasons: Set(events.map(\.reason)),
                firstAt: events.map(\.at).min() ?? newest.at,
                latestAt: newest.at,
                sample: reached.max(by: { $0.at < $1.at }) ?? newest
            )
        }

        return groups.sorted {
            if $0.reached != $1.reached { return $0.reached > $1.reached }
            return $0.latestAt > $1.latestAt
        }
    }

    private static func name(of events: [BlockEvent]) -> String {
        if let artistRow = events.first(where: { $0.itemID.kind == .artist }) {
            return artistRow.displayName
        }
        return events.max(by: { $0.at < $1.at })?.displayName ?? ""
    }
}

// MARK: - Origins

/// Where a play or a block came from, in a parent's words.
///
/// Resolved offline from the columns a row already carries. Names are whatever
/// is already known; a screen never blocks on a catalog fetch to draw a row.
public enum OriginDescription: Sendable, Hashable {
    case home
    case search(term: String)

    /// `name` is `nil` when the catalog has not been asked, or could not
    /// answer — the row then reads as the kind of thing it was.
    case browse(CatalogID, name: String?)
    case catalogPlaylist(CatalogID, name: String?)

    /// `name` is `nil` when the kid has since deleted the playlist. There is no
    /// fallback: this is the one identifier in the store that is ours rather
    /// than Apple's, and nothing else remembers what it was called.
    case kidPlaylist(UUID, name: String?)

    /// The stored columns did not read back. Not a guess at `.home` — a report
    /// that silently claims every orphaned row came from the home screen is
    /// worse than one that admits it does not know.
    case unknown
}

extension PlaybackOrigin {
    /// Describes this origin using only what is already in hand.
    ///
    /// - Parameters:
    ///   - kidPlaylistName: names of the kid's playlists, by local identifier.
    ///   - catalogName: whatever the caller can supply without waiting — a warm
    ///     cache, typically. Returning `nil` is always acceptable.
    public func described(
        kidPlaylistName: (UUID) -> String? = { _ in nil },
        catalogName: (CatalogID) -> String? = { _ in nil }
    ) -> OriginDescription {
        switch self {
        case .home: .home
        case .search(let term): .search(term: term)
        case .browse(let id): .browse(id, name: catalogName(id))
        case .playlist(let id): .catalogPlaylist(id, name: catalogName(id))
        case .kidPlaylist(let local): .kidPlaylist(local, name: kidPlaylistName(local))
        }
    }
}
