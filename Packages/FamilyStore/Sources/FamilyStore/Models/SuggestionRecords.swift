import Foundation
import PolicyEngine
import SwiftData

/// A suggestion widens reach: non-dismissed rows fold into policy as allows.
@Model
public final class SuggestionRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// `nil` only for a snapshot playlist — see ``SuggestionTarget``.
    public private(set) var catalogID: String?

    /// `ItemKind.rawValue`; part of identity since catalog ids aren't type-unique.
    public private(set) var itemKind: String = ItemKind.album.rawValue

    /// Copied at write time so the shelf renders offline for a delisted item.
    public private(set) var displayName: String = ""

    /// Artist under an album, curator under a playlist; copied the same way.
    public private(set) var subtitle: String?

    /// A reference only. Artwork bytes are never copied into our storage.
    public private(set) var artworkURL: URL?

    public private(set) var suggestedAt: Date = Date.distantPast

    /// One past the highest at insert, so adding never rewrites neighboring rows.
    public private(set) var position: Int = 0

    /// Local UUID for a kid's own playlist — the one non-catalog stored id.
    public private(set) var sourcePlaylistID: UUID?

    /// When passed on; combine with ``restoredAt`` via ``isDismissed``, not alone.
    public private(set) var dismissedAt: Date?

    /// When re-offered; `nil` also means never-restored for pre-column rows.
    public private(set) var restoredAt: Date?

    /// A parent's note, shown to the kid — plan for that before the field exists.
    public private(set) var note: String?

    /// Which grown-up picked it, by id, so co-attributed grown-ups share a shelf.
    public private(set) var addedBy: String?

    /// Name as suggested, copied like ``displayName``; rewritten only on rename.
    public private(set) var addedByName: String?

    public var kid: Kid?

    /// The resolved songs, for a playlist. Empty for every other kind.
    @Relationship(deleteRule: .cascade, inverse: \SuggestionEntryRecord.suggestion)
    public private(set) var entries: [SuggestionEntryRecord] = []

    public init(
        id: UUID = UUID(),
        target: SuggestionTarget,
        displayName: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        position: Int,
        note: String? = nil,
        addedBy: String? = nil,
        addedByName: String? = nil,
        at: Date = .now
    ) {
        self.id = id
        switch target {
        case .catalog(let catalogID):
            self.catalogID = catalogID.rawValue
            self.itemKind = catalogID.kind.rawValue
        case .snapshotPlaylist(let local):
            // Own id, not the playlist's — reuse let two suggesters collide.
            self.sourcePlaylistID = local
            self.catalogID = nil
            self.itemKind = ItemKind.playlist.rawValue
        }
        self.displayName = displayName
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.position = position
        self.note = note
        self.addedBy = addedBy
        self.addedByName = addedByName
        self.suggestedAt = at
        self.modifiedAt = at
    }

    /// Internal: the only way to build a row this version can't read, for tests.
    init(
        id: UUID = UUID(),
        rawItemKind: String,
        catalogID: String?,
        displayName: String,
        position: Int = 0,
        at: Date = .now
    ) {
        self.id = id
        self.catalogID = catalogID
        self.itemKind = rawItemKind
        self.displayName = displayName
        self.position = position
        self.suggestedAt = at
        self.modifiedAt = at
    }

    // MARK: - Mutation

    /// Upsert: refreshes metadata and reassigns attribution, but not position.
    func refresh(
        displayName: String,
        subtitle: String?,
        artworkURL: URL?,
        note: String?,
        addedBy: String? = nil,
        addedByName: String? = nil,
        at: Date = .now
    ) {
        self.displayName = displayName
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        // Set-only: a note-less re-suggestion must not erase an existing note.
        if let note { self.note = note }
        self.addedBy = addedBy
        self.addedByName = addedByName
        self.modifiedAt = at
    }

    /// Corrects the copied name after a grown-up renames themselves.
    func rewriteAddedByName(to newName: String, at: Date = .now) {
        addedByName = newName
        modifiedAt = at
    }

    /// Stamps `modifiedAt`, unlike other kid-side writes, because this changes reach.
    public func dismiss(at: Date = .now) {
        guard dismissedAt == nil else { return }
        dismissedAt = at
        modifiedAt = at
    }

    /// Moves it to the front — a re-offer is worth nothing if the kid never sees it.
    public func restore(position newPosition: Int, at: Date = .now) {
        // Stamps, never clears — clearing would let a merge silently drop the restore.
        restoredAt = at
        position = newPosition
        suggestedAt = at
        modifiedAt = at
    }

    public func setNote(_ newNote: String?, at: Date = .now) {
        note = newNote
        modifiedAt = at
    }

    /// Appends a resolved song, or does nothing if already here; ancestry required.
    @discardableResult
    public func addSong(
        id songID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        ancestry: LibraryAncestry = .none,
        at: Date = .now
    ) -> SuggestionEntryRecord? {
        guard songID.kind == .song else { return nil }
        guard !entries.contains(where: { $0.catalogID == songID.rawValue }) else { return nil }

        let record = SuggestionEntryRecord(
            catalogID: songID,
            displayName: displayName,
            artworkURL: artworkURL,
            position: entries.count,
            ancestry: ancestry,
            at: at
        )
        entries.append(record)
        record.suggestion = self
        modifiedAt = at
        return record
    }

    // MARK: - Reading

    /// `nil` for a row this version can't read — dropped, never guessed or denied.
    public var target: SuggestionTarget? {
        guard let kind = ItemKind(rawValue: itemKind) else { return nil }
        if let catalogID, !catalogID.isEmpty {
            return .catalog(CatalogID(kind, catalogID))
        }
        guard kind == .playlist else { return nil }
        // Falls back to `id` for rows predating this column — no backfill needed.
        return .snapshotPlaylist(local: sourcePlaylistID ?? id)
    }

    /// Plain comparison: one device's order isn't ambiguous, unlike a merge's.
    public var isDismissed: Bool {
        guard let dismissedAt else { return false }
        guard let restoredAt else { return true }
        return dismissedAt > restoredAt
    }

    /// A playlist's allow reaches the container and its tracks, not by lineage.
    public var allowedIDs: [CatalogID] {
        // `isDismissed`, not `dismissedAt == nil` — a restore stamps, doesn't clear.
        guard !isDismissed, let target else { return [] }
        var ids: [CatalogID] = []
        if case .catalog(let id) = target { ids.append(id) }
        ids.append(contentsOf: entries.map(\.itemID))
        return ids
    }

    /// The value form, or `nil` for a row this version cannot read.
    public var row: SuggestionRow? {
        guard let target else { return nil }
        return SuggestionRow(
            id: id,
            target: target,
            displayName: displayName,
            subtitle: subtitle,
            artworkURL: artworkURL,
            suggestedAt: suggestedAt,
            position: position,
            dismissedAt: dismissedAt,
            restoredAt: restoredAt,
            note: note,
            addedBy: addedBy,
            addedByName: addedByName,
            entries: entries.sorted(by: SuggestionEntryRecord.inOrder).map(\.row)
        )
    }
}

/// Not a ``PlaylistEntryRecord``: that table is read into the kid's own shelf.
@Model
public final class SuggestionEntryRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// Always a song; no `itemKind` column because nothing else lands here.
    public private(set) var catalogID: String = ""

    public private(set) var displayName: String = ""
    public private(set) var artworkURL: URL?

    /// 0-based, in the order the parent's playlist had them.
    public private(set) var position: Int = 0
    public private(set) var addedAt: Date = Date.distantPast

    // MARK: - Ancestry
    //
    // Empty ancestry costs the gapless join and lets a bare id skip
    // `firstDenied`'s artist walk — a real deny-bypass, not hypothetical.

    public private(set) var albumID: String?
    public private(set) var albumName: String?
    public private(set) var artistID: String?
    public private(set) var artistName: String?
    public private(set) var artistArtworkURL: URL?

    public var suggestion: SuggestionRecord?

    public init(
        id: UUID = UUID(),
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        position: Int,
        ancestry: LibraryAncestry = .none,
        at: Date = .now
    ) {
        self.id = id
        self.catalogID = catalogID.rawValue
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.position = position
        self.addedAt = at
        self.modifiedAt = at
        apply(ancestry)
    }

    /// Records lineage learned after the fact.
    public func record(ancestry: LibraryAncestry, at: Date = .now) {
        guard !ancestry.isEmpty else { return }
        apply(ancestry)
        modifiedAt = at
    }

    private func apply(_ ancestry: LibraryAncestry) {
        albumID = ancestry.albumID
        albumName = ancestry.albumName
        artistID = ancestry.artistID
        artistName = ancestry.artistName
        artistArtworkURL = ancestry.artistArtworkURL
    }

    public var itemID: CatalogID { CatalogID(.song, catalogID) }

    public var ancestry: LibraryAncestry {
        LibraryAncestry(
            albumID: albumID,
            albumName: albumName,
            artistID: artistID,
            artistName: artistName,
            artistArtworkURL: artistArtworkURL
        )
    }

    public var row: PlaylistEntryRow {
        PlaylistEntryRow(
            id: id,
            catalogID: itemID,
            displayName: displayName,
            artworkURL: artworkURL,
            position: position,
            addedAt: addedAt,
            ancestry: ancestry
        )
    }
}

extension SuggestionEntryRecord {
    /// Mirrors ``PlaylistEntryRecord/inOrder(_:_:)`` for a suggested playlist.
    static func inOrder(_ a: SuggestionEntryRecord, _ b: SuggestionEntryRecord) -> Bool {
        (a.position, a.id.uuidString) < (b.position, b.id.uuidString)
    }
}

extension SuggestionRecord {
    /// Newest first; two offline grown-ups often collide on the same position.
    static func newestFirst(_ a: SuggestionRecord, _ b: SuggestionRecord) -> Bool {
        (a.position, a.id.uuidString) > (b.position, b.id.uuidString)
    }
}

// MARK: - Absorbing a record another device wrote

extension SuggestionRecord {
    func applySync(
        displayName: String,
        subtitle: String?,
        artworkURL: URL?,
        note: String?,
        addedBy: String?,
        addedByName: String?,
        position: Int?,
        suggestedAt: Date?,
        dismissedAt: Date?,
        restoredAt: Date?,
        sourcePlaylistID: UUID?,
        at: Date
    ) {
        self.displayName = displayName
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.note = note
        self.addedBy = addedBy
        self.addedByName = addedByName
        if let position { self.position = position }
        if let suggestedAt { self.suggestedAt = suggestedAt }

        // Advance-only: absence must never read as "never dismissed" (withdraws an allow).
        if let dismissedAt, dismissedAt > (self.dismissedAt ?? .distantPast) {
            self.dismissedAt = dismissedAt
        }
        if let restoredAt, restoredAt > (self.restoredAt ?? .distantPast) {
            self.restoredAt = restoredAt
        }

        // Fills in only for a pre-column row; never overwrites one that has it.
        if let sourcePlaylistID, self.sourcePlaylistID == nil {
            self.sourcePlaylistID = sourcePlaylistID
        }
        modifiedAt = at
    }
}

extension SuggestionRecord {
    /// Internal: `SyncApply` uses this for a row that arrived with its own id.
    func attach(_ record: SuggestionEntryRecord) {
        entries.append(record)
        record.suggestion = self
    }
}

extension SuggestionEntryRecord {
    func applySync(
        position: Int?,
        addedAt: Date?,
        displayName: String,
        artworkURL: URL?,
        ancestry: LibraryAncestry,
        at: Date
    ) {
        if let position { self.position = position }
        if let addedAt { self.addedAt = min(self.addedAt, addedAt) }
        self.displayName = displayName
        self.artworkURL = artworkURL
        if !ancestry.isEmpty { apply(ancestry) }
        modifiedAt = at
    }
}
