import Foundation
import PolicyEngine

/// Unfiltered — every other read drops blocks; the parent's screen needs them.
public struct ReviewWindow: Sendable {
    public let kidID: UUID

    /// Always bounded — open-ended means an unlimited fetch over the biggest table.
    public let interval: DateInterval

    public let plays: [PlayEvent]
    public let searches: [SearchEvent]
    public let blocks: [ReviewedBlock]

    /// Raw visit rows — the Recent shelf is a projection, but the report reads these.
    public let visits: [VisitEvent]

    /// Count, not rows — a silent zero and a silent forty must not look the same.
    public let unreadable: Int

    /// A play row is written on stop, so the song playing right now has none yet.
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

/// Exists before the sweep — else a swept week reads the same as an empty one.
public enum Coverage: Sendable, Hashable {
    /// Raw events cover the whole interval.
    case complete

    /// Raw events exist only after this date; before it there are summaries only.
    case summarisedBefore(Date)
}

/// A block with the entry that produced it resolved to a parent-readable name.
public struct ReviewedBlock: Sendable {
    public let event: BlockEvent

    /// Never re-derived from today's rules — that would invent a fact, not report one.
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

/// `Codable`; `reasons` sorts to an array — a `Set`'s byte encoding isn't stable.
public struct BlockGroup: Sendable, Identifiable, Codable, Equatable {
    /// `nil` when no row resolved an artist — keyed by name, can't widen to one.
    public let artistID: CatalogID?
    public let displayName: String

    /// Split, never summed — `unseen` reflects our filter, not the child.
    public let reached: Int
    public let unseen: Int

    /// More than one when different rules caught different tracks.
    public let reasons: Set<BlockReason>

    public let firstAt: Date
    public let latestAt: Date

    /// The reached row if any, else newest — its origin turns a group into a sentence.
    public let sample: BlockEvent

    public var id: String { artistID.map(\.rawValue) ?? "name:\(displayName)" }

    public var total: Int { reached + unseen }

    /// Explicit: the custom `init(from:)` below suppresses the memberwise one.
    public init(
        artistID: CatalogID?,
        displayName: String,
        reached: Int,
        unseen: Int,
        reasons: Set<BlockReason>,
        firstAt: Date,
        latestAt: Date,
        sample: BlockEvent
    ) {
        self.artistID = artistID
        self.displayName = displayName
        self.reached = reached
        self.unseen = unseen
        self.reasons = reasons
        self.firstAt = firstAt
        self.latestAt = latestAt
        self.sample = sample
    }

    // MARK: - Coding

    enum CodingKeys: String, CodingKey {
        case artistID = "art"
        case displayName = "n"
        case reached = "r"
        case unseen = "u"
        case reasons = "rsn"
        case firstAt = "f"
        case latestAt = "l"
        case sample = "smp"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(artistID, forKey: .artistID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(reached, forKey: .reached)
        try container.encode(unseen, forKey: .unseen)
        // Sorted by frozen name, so the same set always encodes the same bytes.
        try container.encode(
            reasons.sorted { $0.stored.name < $1.stored.name }, forKey: .reasons)
        try container.encode(firstAt, forKey: .firstAt)
        try container.encode(latestAt, forKey: .latestAt)
        try container.encode(sample, forKey: .sample)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artistID = try container.decodeIfPresent(CatalogID.self, forKey: .artistID)
        displayName = try container.decode(String.self, forKey: .displayName)
        reached = try container.decode(Int.self, forKey: .reached)
        unseen = try container.decode(Int.self, forKey: .unseen)
        reasons = Set(try container.decode([BlockReason].self, forKey: .reasons))
        firstAt = try container.decode(Date.self, forKey: .firstAt)
        latestAt = try container.decode(Date.self, forKey: .latestAt)
        sample = try container.decode(BlockEvent.self, forKey: .sample)
    }
}

extension BlockGroup {
    /// Reached-first — sorting by volume would rank the catalog, not this family.
    public static func group(_ blocks: [ReviewedBlock]) -> [BlockGroup] {
        // Keyed by artist, else by name — an unresolved lineage is shown, not dropped.
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
                // Artist's own name if blocked, else newest track's — best label with no catalog.
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

/// Resolved offline — never blocks a screen on a catalog fetch to draw a row.
public enum OriginDescription: Sendable, Hashable {
    case home
    case search(term: String)

    /// `name` is `nil` when uncataloged — the row still reads as its kind.
    case browse(CatalogID, name: String?)
    case catalogPlaylist(CatalogID, name: String?)

    /// `name` is `nil` post-delete — our own identifier, so nothing else recalls it.
    case kidPlaylist(UUID, name: String?)

    /// Kept separate from `.home` to answer: did they play what I suggested?
    case suggestion

    /// `name` is `nil` once withdrawn — like `kidPlaylist`, nothing else recalls it.
    case suggestedPlaylist(UUID, name: String?)

    /// Never guessed as `.home` — a wrong claim is worse than admitting we don't know.
    case unknown
}

extension PlaybackOrigin {
    /// Resolves names from caller-supplied lookups only — never waits on any of them.
    public func described(
        kidPlaylistName: (UUID) -> String? = { _ in nil },
        suggestionName: (UUID) -> String? = { _ in nil },
        catalogName: (CatalogID) -> String? = { _ in nil }
    ) -> OriginDescription {
        switch self {
        case .home: .home
        case .search(let term): .search(term: term)
        case .browse(let id): .browse(id, name: catalogName(id))
        case .playlist(let id): .catalogPlaylist(id, name: catalogName(id))
        case .kidPlaylist(let local): .kidPlaylist(local, name: kidPlaylistName(local))
        case .suggestion: .suggestion
        case .suggestedPlaylist(let local): .suggestedPlaylist(local, name: suggestionName(local))
        }
    }
}
