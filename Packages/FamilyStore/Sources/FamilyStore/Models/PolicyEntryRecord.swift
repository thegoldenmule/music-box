import Foundation
import PolicyEngine
import SwiftData

/// One allow/deny row. `catalogID` is always canonical — never a library id.
@Model
public final class PolicyEntryRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// `"allow"` or `"deny"` — `PolicyEntry.Kind.rawValue`.
    public private(set) var kind: String = PolicyEntry.Kind.deny.rawValue

    /// `ItemKind.rawValue` — ids collide across types without this discriminator.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    public private(set) var catalogID: String = ""

    /// Copied at add time, never refreshed — trades freshness for offline reads.
    public private(set) var displayName: String = ""

    /// A reference only. Artwork bytes are never copied into our storage.
    public private(set) var artworkURL: URL?

    public private(set) var addedAt: Date = Date.distantPast

    /// Which ``GrownUp`` added it. `nil` means the roster was empty then.
    public private(set) var addedBy: String?

    /// Copied name for offline rendering; only ``renameGrownUp`` may correct it.
    public private(set) var addedByName: String?

    /// Which device wrote it, distinct from `addedBy` — unrecoverable once lost.
    public private(set) var originatingDeviceID: UUID?

    /// Re-assert time; keeps ``addedAt``'s "added on Tuesday" sentence stable.
    public private(set) var assertedAt: Date = Date.distantPast

    /// Retraction, not delete — a tombstone exports; a deleted row cannot.
    public private(set) var retractedAt: Date?

    public var kid: Kid?

    public init(
        id: UUID = UUID(),
        kind: PolicyEntry.Kind,
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        addedBy: String? = nil,
        addedByName: String? = nil,
        originatingDeviceID: UUID? = nil,
        at: Date = .now
    ) {
        self.id = id
        self.originatingDeviceID = originatingDeviceID
        self.kind = kind.rawValue
        self.itemKind = catalogID.kind.rawValue
        self.catalogID = catalogID.rawValue
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.addedBy = addedBy
        self.addedByName = addedByName
        self.addedAt = at
        self.modifiedAt = at
    }

    /// Corrects the copied name; called from ``Family/renameGrownUp(_:to:at:)``.
    func rewriteAddedByName(to newName: String, at: Date = .now) {
        addedByName = newName
        modifiedAt = at
    }

    /// Builds from raw strings — the only way to make an unreadable row.
    init(
        id: UUID = UUID(),
        rawKind: String,
        rawItemKind: String,
        catalogID: String,
        displayName: String,
        artworkURL: URL? = nil,
        addedBy: String? = nil,
        at: Date = .now
    ) {
        self.id = id
        self.kind = rawKind
        self.itemKind = rawItemKind
        self.catalogID = catalogID
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.addedBy = addedBy
        self.addedAt = at
        self.modifiedAt = at
    }

    /// Typed entry, or `nil` if unreadable — see ``Kid/buildPolicy()``.
    public var entry: PolicyEntry? {
        guard
            let kind = PolicyEntry.Kind(rawValue: kind),
            let itemKind = ItemKind(rawValue: itemKind)
        else { return nil }
        return PolicyEntry(kind: kind, id: CatalogID(itemKind, catalogID))
    }

    // MARK: - Standing

    /// Assumed clock drift — inside it, no device's timestamp outranks the other.
    public static let clockSkewWindow: TimeInterval = 120

    /// Reads through to ``addedAt`` so pre-existing rows default correctly.
    public var assertion: Date { max(assertedAt, addedAt) }

    /// Plain comparison — the skew window is ``Merge``'s job, not one device's.
    public var isLive: Bool {
        guard let retractedAt else { return true }
        return assertion > retractedAt
    }

    /// Withdraws the row without destroying it. See ``retractedAt``.
    public func retract(at: Date = .now) {
        retractedAt = at
        modifiedAt = at
    }

    /// Never clears retractedAt — timestamps only advance, or merge loses info.
    public func reassert(at: Date = .now) {
        assertedAt = at
        modifiedAt = at
    }
}

// MARK: - Absorbing a record another device wrote

// Monotonic — advances or leaves a value, never clears; a safety net under merge.

// Never stamps the local clock — an import must not read as an edit on export.

extension PolicyEntryRecord {
    func applySync(
        addedAt: Date,
        assertedAt: Date?,
        retractedAt: Date?,
        originatingDeviceID: UUID?,
        at: Date
    ) {
        // Earliest wins — a re-add elsewhere must not rewrite the shown sentence.
        self.addedAt = min(self.addedAt, addedAt)

        // Advance only; a missing retractedAt must never read as "put it back".
        if let assertedAt, assertedAt > self.assertedAt { self.assertedAt = assertedAt }
        if let retractedAt, retractedAt > (self.retractedAt ?? .distantPast) {
            self.retractedAt = retractedAt
        }
        if let originatingDeviceID, self.originatingDeviceID == nil {
            self.originatingDeviceID = originatingDeviceID
        }
        modifiedAt = at
    }
}
