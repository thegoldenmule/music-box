import Foundation
import PolicyEngine

/// What an activity segment's payload holds.
///
/// **High write volume, no second reader** — travels batched and opaque, not
/// one record each, so a parent's deny never queues behind blocked searches.
///
/// **Every `CodingKeys` below is frozen** — read back months later, possibly by
/// a build that didn't write them, so a rename must not change the wire.
///
/// **Carries each row's id** so absorbing is idempotent for free: no
/// absorbedAt column, no unbounded set of already-seen segment ids.
public struct ActivitySegment: Codable, Sendable, Equatable {
    /// Bumped on breaking changes; an unknown version is kept, never dropped.
    public static let version = 1

    public let version: Int
    public let rows: [Row]

    public init(rows: [Row], version: Int = ActivitySegment.version) {
        self.version = version
        self.rows = rows
    }

    /// Exactly one of four is set; none means skip it, never invent an event.
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

/// Frozen strings as an enum — a fifth table fails to compile if missed.
public enum ActivityTable: String, Sendable, CaseIterable, Codable {
    case visits
    case searches
    case plays
    case blocks
}

// Events.swift keeps Codable + its frozen CodingKeys together — hardest to drift.
