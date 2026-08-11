import Foundation
import PolicyEngine

/// What an activity segment's payload holds.
///
/// **The events are the great majority of this store's write volume and have no
/// second reader as rows**, which is why they travel batched and opaque rather than
/// one record each. Sending them individually would put a parent's deny behind a
/// backlog of a child's blocked search results, and there is no API to reorder a
/// pending CloudKit queue.
///
/// **Every `CodingKeys` below is frozen.** These bytes are read back out of a
/// parent's history months later, possibly by a build that did not write them, so a
/// property rename must not change the wire. That is the same rule
/// ``PlaybackOrigin`` and ``BlockReason`` follow for their own stored forms, and the
/// reason both of those route through an explicit representation rather than a
/// synthesised one.
///
/// **The payload carries each row's identifier alongside its event**, which is what
/// makes absorbing a segment idempotent with no extra bookkeeping: a device inserts
/// only the ids it does not already have. The alternative was a column recording
/// that a segment had been absorbed, or a device-local set of segment ids that grows
/// without bound.
public struct ActivitySegment: Codable, Sendable, Equatable {
    /// Bumped when the shape of anything below changes in a way an older decoder
    /// cannot read. A segment that says a version this build does not know is
    /// **kept and skipped**, never dropped: the device that wrote it still has the
    /// rows, and a newer build here will read it.
    public static let version = 1

    public let version: Int
    public let rows: [Row]

    public init(rows: [Row], version: Int = ActivitySegment.version) {
        self.version = version
        self.rows = rows
    }

    /// One event and the identity of the row it came from.
    ///
    /// Exactly one of the four is set, matching the segment's `table` column. A
    /// `Row` with none is a row this build cannot place, and absorbing skips it
    /// rather than inventing an event.
    public struct Row: Codable, Sendable, Equatable {
        public let id: UUID
        public var visit: VisitEvent?
        public var search: SearchEvent?
        public var play: PlayEvent?
        public var block: BlockEvent?

        public init(
            id: UUID,
            visit: VisitEvent? = nil,
            search: SearchEvent? = nil,
            play: PlayEvent? = nil,
            block: BlockEvent? = nil
        ) {
            self.id = id
            self.visit = visit
            self.search = search
            self.play = play
            self.block = block
        }

        enum CodingKeys: String, CodingKey {
            case id = "i"
            case visit = "v"
            case search = "s"
            case play = "p"
            case block = "b"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version = "ver"
        case rows = "r"
    }
}

// MARK: - Which table a segment carries

/// The four event tables, as the `table` column spells them.
///
/// **Frozen strings**, and an enum rather than a raw string at the call sites so a
/// fifth table cannot be added without every switch here failing to compile.
public enum ActivityTable: String, Sendable, CaseIterable, Codable {
    case visits
    case searches
    case plays
    case blocks
}

// The four event values are `Codable` in `Events.swift`, beside the properties
// their frozen `CodingKeys` freeze — Swift only synthesises the conformance in the
// type's own file, and putting the keys next to the fields is where they are
// hardest to change by accident anyway.
