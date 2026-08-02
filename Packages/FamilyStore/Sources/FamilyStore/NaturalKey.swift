import CryptoKit
import Foundation

/// What makes a row *the same row* across two devices.
///
/// **Every upsert in this store is a local-read dedup**, which is correct under
/// one writer and is not one under two. `Kid.addEntry` looks for a matching row
/// and re-asserts it; `Kid.addFavorite` upserts; `addSuggestion` matches on
/// target. Every one of those asks "is it already here?" of a store that has
/// only seen this device's writes. Two parents adding the same deny offline both
/// answer no.
///
/// So the identity has to be computed from the content rather than looked up.
/// Two devices producing the same logical row produce the **same record name**,
/// which turns a duplicate into a save conflict the merge resolves — instead of
/// two rows with one meaning and nothing able to tell they are the same. Under a
/// mirroring layer that would instead be a deferred cleanup sweep picking a
/// winner by identifier, long after both are on screen.
///
/// The consequence worth stating plainly: **a record name is the record's
/// identity on the server, and changing how it is derived forks every existing
/// record into a duplicate.** These strings are as permanent as a column.
public enum NaturalKey {
    /// Records whose identity is their own UUID, because they genuinely are one
    /// thing that one person created.
    ///
    /// A kid, a grown-up, a household, a playlist, a device, a decision, a
    /// consent, a clear: two devices cannot independently invent the same one,
    /// so there is nothing to collapse and the identifier is the honest key.
    public static func identity(_ id: UUID) -> String { id.uuidString }

    /// `(kid, kind, itemKind, catalogID)` — a policy entry.
    ///
    /// `kind` is in the key on purpose. An allow and a deny on the same artist
    /// are two different statements, and folding them onto one record would make
    /// a parent's allow and another parent's deny overwrite each other silently
    /// rather than both existing for the engine to resolve — where a deny
    /// already wins.
    public static func policyEntry(
        kid: UUID, kind: String, itemKind: String, catalogID: String
    ) -> String {
        key("policyEntry", kid.uuidString, kind, itemKind, catalogID)
    }

    /// `(kid, itemKind, catalogID)` — a favorite. No `kind`: a favorite is one
    /// statement and the store already upserts it.
    public static func favorite(kid: UUID, itemKind: String, catalogID: String) -> String {
        key("favorite", kid.uuidString, itemKind, catalogID)
    }

    /// `(playlist, catalogID)` — a song in a playlist.
    ///
    /// Position is deliberately **not** in the key. The same song at a different
    /// position is the same song moved, not a second row, and keying on position
    /// would make a reorder look like a bulk delete-and-insert.
    public static func playlistEntry(playlist: UUID, catalogID: String) -> String {
        key("playlistEntry", playlist.uuidString, catalogID)
    }

    /// `(kid, target)` — a suggestion, where the target is a catalog identifier
    /// or a local playlist.
    ///
    /// This is the one the old schema got wrong in a way that mattered: the
    /// record took the playlist's UUID *as its own id*, so two grown-ups
    /// suggesting one playlist produced two records with an identical key and
    /// nothing to catch it.
    public static func suggestion(kid: UUID, target: String) -> String {
        key("suggestion", kid.uuidString, target)
    }

    /// `(suggestion, catalogID)` — a resolved track under a suggested playlist.
    public static func suggestionEntry(suggestion: UUID, catalogID: String) -> String {
        key("suggestionEntry", suggestion.uuidString, catalogID)
    }

    /// `(kid, weekStart)` — a weekly summary. Two devices sweeping the same week
    /// must produce one record, which is also why the sweep needs a single
    /// owner: this stops the duplicate, not the double work.
    public static func weeklySummary(kid: UUID, weekStart: Date) -> String {
        key("weeklySummary", kid.uuidString, String(Int(weekStart.timeIntervalSince1970)))
    }

    /// `(kid, device, day, table, index)` — an activity segment.
    ///
    /// **The device is in the key, and that is what gives the volume leader in
    /// this store no conflict surface at all.** Two devices never write the same
    /// segment, so ninety-odd percent of the traffic cannot conflict by
    /// construction rather than by luck. The property is only as strong as the
    /// device identity is stable: a Keychain identity that churns re-keys future
    /// segments and can re-export a device's history under a new name. That is a
    /// duplicate, not a loss, and it is the honest limit of the claim.
    public static func activitySegment(
        kid: UUID, device: UUID, dayUTC: String, table: String, index: Int
    ) -> String {
        key("segment", kid.uuidString, device.uuidString, dayUTC, table, String(index))
    }

    // MARK: -

    /// Hashes the parts into a stable, opaque record name.
    ///
    /// Hashed rather than joined for two reasons, and neither is tidiness.
    /// CloudKit record names have a length limit and a restricted character set,
    /// while these parts include free text a person typed — a playlist name, a
    /// catalog identifier of unknown shape. And a joined key leaks its contents:
    /// a record *name* is metadata, and the name of a record in a child's zone
    /// should not spell out what the child listened to.
    ///
    /// SHA-256, truncated to 32 hex characters. Collision at that width is not a
    /// practical concern for a household's worth of rows, and the separator
    /// makes `("a", "bc")` and `("ab", "c")` different keys rather than the same
    /// one.
    static func key(_ parts: String...) -> String {
        let joined = parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
