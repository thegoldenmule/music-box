import Foundation
import PolicyEngine
import SwiftData

/// One row on a kid's allow or deny list.
///
/// Allow and deny share a table with a flag rather than living in two tables:
/// they have the same shape, the engine reads them together, and splitting them
/// would mean writing every lookup twice.
///
/// `catalogID` is **always** an Apple Music catalog identifier. Library picks
/// are resolved to their catalog equivalents before they reach here, and
/// library identifiers are never stored. One namespace is why a deny on an
/// artist reaches that artist's tracks, and why this record needs no scope
/// field.
@Model
public final class PolicyEntryRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// `"allow"` or `"deny"` — `PolicyEntry.Kind.rawValue`.
    public private(set) var kind: String = PolicyEntry.Kind.deny.rawValue

    /// `ItemKind.rawValue`. Part of the identity: MusicKit identifiers are only
    /// unique within a type, so an album id could otherwise collide with a song
    /// id and quietly widen a parent's list.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    public private(set) var catalogID: String = ""

    /// Copied at add time and never refreshed. A renamed album keeps the name
    /// it had, and a delisted one still reads as a name instead of an
    /// identifier. Freshness traded for the list rendering offline.
    public private(set) var displayName: String = ""

    /// A reference only. Artwork bytes are never copied into our storage.
    public private(set) var artworkURL: URL?

    public private(set) var addedAt: Date = Date.distantPast

    /// Which ``GrownUp`` added it — their `attribution`, not their name. `nil`
    /// when the roster is empty, which is how a household that never names
    /// anybody works.
    public private(set) var addedBy: String?

    /// Their name as it read when this was added, copied for the same reason
    /// ``displayName`` is: the shelf renders offline, and a grown-up taken off
    /// the roster still reads as a name.
    ///
    /// The one thing that rewrites it is ``Family/renameGrownUp(_:to:at:)`` —
    /// see there for why this copy is the exception that gets corrected.
    public private(set) var addedByName: String?

    /// Which device this was typed on. `nil` for every row written before the
    /// column existed, which is the truthful answer rather than a gap.
    ///
    /// `addedBy` says which *grown-up* claims it; this says which *machine*
    /// wrote it, and the two answer different questions. When a deny turns up
    /// twice, or turns up and then does not, this is the column that makes it
    /// diagnosable instead of a mystery — and it cannot be recovered later,
    /// because it exists nowhere else once the row is written.
    public private(set) var originatingDeviceID: UUID?

    /// When this row was last **asserted**, if it has been re-added since it was
    /// first created. `.distantPast` on every row that has only ever been added
    /// once, which is why ``assertion`` reads through to ``addedAt``.
    ///
    /// Two columns rather than one mutable `addedAt` because `addedAt` is what
    /// the admin shows a parent — *"you added this on Tuesday"* — and a re-add
    /// after a retraction should not rewrite that sentence.
    public private(set) var assertedAt: Date = Date.distantPast

    /// When this row was **withdrawn**, or `nil` while it stands.
    ///
    /// **Removal is a retraction, not a delete, and that is the whole
    /// mechanism.** Two parents editing one list offline produce independent
    /// field changes on independent rows; nothing is co-written, every device
    /// computes the same live set from the same timestamps, and there is
    /// nothing to arbitrate. Last-write-wins over a whole list — the thing the
    /// spec forbids outright — never comes up, because there is no list-shaped
    /// value to write.
    ///
    /// It is also the only tombstone available. A deleted row leaves nothing to
    /// enumerate, so a delete can never be exported and a co-parent's device
    /// keeps the entry forever.
    ///
    /// `nil` is the default and the truthful value for every row that predates
    /// the column: nothing had been retracted, because nothing could be.
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

    /// Corrects the copied name after a rename. See ``Family/renameGrownUp(_:to:at:)``.
    func rewriteAddedByName(to newName: String, at: Date = .now) {
        addedByName = newName
        modifiedAt = at
    }

    /// Builds a row straight from stored strings, bypassing the typed enums.
    ///
    /// Internal, and the only way to produce a row this version cannot read —
    /// which is exactly what the fail-closed path in
    /// ``Kid/buildPolicy()`` has to be tested against.
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

    /// The typed entry, or `nil` if the stored strings do not make one.
    ///
    /// See ``Kid/buildPolicy()`` for what happens to a row that lands here —
    /// the answer is deliberately not "skip it".
    public var entry: PolicyEntry? {
        guard
            let kind = PolicyEntry.Kind(rawValue: kind),
            let itemKind = ItemKind(rawValue: itemKind)
        else { return nil }
        return PolicyEntry(kind: kind, id: CatalogID(itemKind, catalogID))
    }

    // MARK: - Standing

    /// How far apart two device clocks are assumed to be able to drift.
    ///
    /// Inside this window an assert and a retract are **too close to call**.
    /// Neither device is wrong; they simply do not agree what "after" means, and
    /// picking the later timestamp is picking whichever device's clock ran fast.
    public static let clockSkewWindow: TimeInterval = 120

    /// The moment this row was last claimed to stand.
    ///
    /// Reads through to ``addedAt`` for a row that has never been re-asserted,
    /// which is what lets the columns above default to `.distantPast` and `nil`
    /// and still be right about every row written before they existed.
    public var assertion: Date { max(assertedAt, addedAt) }

    /// Whether this row is part of the policy right now.
    ///
    /// **Fails closed inside the skew window, and the asymmetry is the point.**
    /// When an assert and a retract land within ``clockSkewWindow`` of each
    /// other, a **deny stands** and an **allow does not**. A phantom deny hides
    /// one item a parent meant to allow: visible on the screen they are already
    /// looking at, and fixable in one tap. A deny that loses a coin-toss against
    /// a stale retraction silently un-blocks something a parent explicitly
    /// refused, and nothing on any screen says so.
    ///
    /// It is the same direction `buildPolicy()` takes on an unreadable row and
    /// the same one `UnratedBehavior.block` takes on a missing rating — one
    /// level up, and for the same reason.
    public var isLive: Bool {
        guard let retractedAt else { return true }
        let interval = assertion.timeIntervalSince(retractedAt)
        guard abs(interval) >= Self.clockSkewWindow else {
            return kind == PolicyEntry.Kind.deny.rawValue
        }
        return interval > 0
    }

    /// Withdraws the row without destroying it. See ``retractedAt``.
    public func retract(at: Date = .now) {
        retractedAt = at
        modifiedAt = at
    }

    /// Puts a retracted row back.
    ///
    /// **Does not clear ``retractedAt``**, deliberately. Both timestamps only
    /// ever move forward, so the comparison in ``isLive`` decides — and a device
    /// that has not yet seen the retraction cannot resurrect the row merely by
    /// having an older copy with no retraction on it. Clearing the column would
    /// throw away the fact the merge needs.
    public func reassert(at: Date = .now) {
        assertedAt = at
        modifiedAt = at
    }
}
