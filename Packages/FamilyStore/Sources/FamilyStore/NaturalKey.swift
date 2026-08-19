import CryptoKit
import Foundation

// What makes a row the same row across two devices. Two pieces of why, both
// load-bearing: every upsert here is a local-read dedup, correct under one
// writer and not under two (two parents adding the same deny offline both see
// no existing row), so identity must come from content — two devices then
// produce the same record name, which turns a duplicate into a save conflict
// the merge resolves, rather than two rows nothing can tell apart. And a
// record name is the record's identity on the server, so changing how any of
// these are derived forks every existing record into a duplicate — these
// strings are as permanent as a column.
public enum NaturalKey {
    /// Own UUID as identity — two devices can't independently invent the same one.
    public static func identity(_ id: UUID) -> String { id.uuidString }

    /// `kind` is in the key so an allow and a deny don't silently overwrite.
    public static func policyEntry(
        kid: UUID, kind: String, itemKind: String, catalogID: String
    ) -> String {
        key("policyEntry", kid.uuidString, kind, itemKind, catalogID)
    }

    /// No `kind`: a favorite is one statement, and the store already upserts it.
    public static func favorite(kid: UUID, itemKind: String, catalogID: String) -> String {
        key("favorite", kid.uuidString, itemKind, catalogID)
    }

    /// Position isn't in the key — a reorder must not look like delete-and-insert.
    public static func playlistEntry(playlist: UUID, catalogID: String) -> String {
        key("playlistEntry", playlist.uuidString, catalogID)
    }

    /// The old schema keyed on the playlist's own id — two suggesters collided.
    public static func suggestion(kid: UUID, target: String) -> String {
        key("suggestion", kid.uuidString, target)
    }

    /// `(suggestion, catalogID)` — a resolved track under a suggested playlist.
    public static func suggestionEntry(suggestion: UUID, catalogID: String) -> String {
        key("suggestionEntry", suggestion.uuidString, catalogID)
    }

    /// Two devices sweeping one week must produce one record, not the double work.
    public static func weeklySummary(kid: UUID, weekStart: Date) -> String {
        key("weeklySummary", kid.uuidString, String(Int(weekStart.timeIntervalSince1970)))
    }

    /// Device is in the key: two devices never write the same segment.
    public static func activitySegment(
        kid: UUID, device: UUID, dayUTC: String, table: String, index: Int
    ) -> String {
        key("segment", kid.uuidString, device.uuidString, dayUTC, table, String(index))
    }

    // MARK: -

    /// Hashed, not joined: a record name is metadata that must not leak a kid's plays.
    static func key(_ parts: String...) -> String {
        let joined = parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
