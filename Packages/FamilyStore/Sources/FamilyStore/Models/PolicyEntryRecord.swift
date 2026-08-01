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

    public var kid: Kid?

    public init(
        id: UUID = UUID(),
        kind: PolicyEntry.Kind,
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        addedBy: String? = nil,
        addedByName: String? = nil,
        at: Date = .now
    ) {
        self.id = id
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
    /// See ``Kid/buildPolicy(unreadableEntriesAs:)`` for what happens to a row
    /// that lands here — the answer is deliberately not "skip it".
    public var entry: PolicyEntry? {
        guard
            let kind = PolicyEntry.Kind(rawValue: kind),
            let itemKind = ItemKind(rawValue: itemKind)
        else { return nil }
        return PolicyEntry(kind: kind, id: CatalogID(itemKind, catalogID))
    }
}
