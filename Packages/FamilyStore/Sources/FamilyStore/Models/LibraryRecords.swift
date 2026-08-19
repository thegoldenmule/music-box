import Foundation
import PolicyEngine
import SwiftData

/// A kid's marked item; exempt from retention like `PlaylistRecord`.
@Model
public final class FavoriteRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// Always an Apple Music catalog ID; library picks resolve to it first.
    public private(set) var catalogID: String = ""

    /// `ItemKind.rawValue`; part of identity since catalog IDs collide across kinds.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    /// Copied at write time so a delisted item still renders offline as a name.
    public private(set) var displayName: String = ""

    /// A reference only. Artwork bytes are never copied into our storage.
    public private(set) var artworkURL: URL?

    public private(set) var favoritedAt: Date = Date.distantPast

    /// `LibraryOrigin.rawValue`.
    public private(set) var origin: String = LibraryOrigin.kid.rawValue

    // MARK: - Ancestry
    // Five flat columns, not one struct: SwiftData blobs can't be predicated on.

    public private(set) var albumID: String?
    public private(set) var albumName: String?
    public private(set) var artistID: String?
    public private(set) var artistName: String?
    public private(set) var artistArtworkURL: URL?

    public var kid: Kid?

    public init(
        id: UUID = UUID(),
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        origin: LibraryOrigin = .kid,
        ancestry: LibraryAncestry = .none,
        at: Date = .now
    ) {
        self.id = id
        self.catalogID = catalogID.rawValue
        self.itemKind = catalogID.kind.rawValue
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.origin = origin.rawValue
        self.favoritedAt = at
        self.modifiedAt = at
        apply(ancestry)
    }

    /// Raw-string init: the only way to make a row this version cannot read.
    init(
        id: UUID = UUID(),
        rawItemKind: String,
        catalogID: String,
        displayName: String,
        rawOrigin: String = LibraryOrigin.kid.rawValue,
        at: Date = .now
    ) {
        self.id = id
        self.catalogID = catalogID
        self.itemKind = rawItemKind
        self.displayName = displayName
        self.origin = rawOrigin
        self.favoritedAt = at
        self.modifiedAt = at
    }

    /// Upsert refresh; `favoritedAt` never moves, so most-recent order stays put.
    func refresh(
        displayName: String,
        artworkURL: URL?,
        origin: LibraryOrigin,
        ancestry: LibraryAncestry = .none,
        at: Date = .now
    ) {
        self.displayName = displayName
        self.artworkURL = artworkURL
        // Kid-tapped never degrades to adopted; the reverse is fine.
        if origin == .kid {
            self.origin = origin.rawValue
        }
        // Ancestry only improves: an unresolved retap must not blank prior lineage.
        if !ancestry.isEmpty {
            apply(ancestry)
        }
        self.modifiedAt = at
    }

    /// Lineage top-up; separate from `refresh` so it never touches the kept name.
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

    /// The typed identifier, or `nil` if the stored strings do not make one.
    public var itemID: CatalogID? {
        guard let kind = ItemKind(rawValue: itemKind) else { return nil }
        return CatalogID(kind, catalogID)
    }

    /// `nil` on unreadable, dropped by `row` — a favorite isn't a permission.
    public var libraryOrigin: LibraryOrigin? { LibraryOrigin(rawValue: origin) }

    public var ancestry: LibraryAncestry {
        LibraryAncestry(
            albumID: albumID,
            albumName: albumName,
            artistID: artistID,
            artistName: artistName,
            artistArtworkURL: artistArtworkURL
        )
    }

    /// The value form, or `nil` for a row this version cannot read.
    public var row: FavoriteRow? {
        guard let itemID, let libraryOrigin else { return nil }
        return FavoriteRow(
            id: id,
            catalogID: itemID,
            displayName: displayName,
            artworkURL: artworkURL,
            favoritedAt: favoritedAt,
            origin: libraryOrigin,
            ancestry: ancestry
        )
    }
}

/// A playlist the kid owns, order included; exempt from retention, too.
@Model
public final class PlaylistRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// Free text a child typed; it reaches Apple Music and the parent's report.
    public private(set) var name: String = ""

    public private(set) var createdAt: Date = Date.distantPast

    /// Apple Music library counterpart ID; `nil` means none exists yet.
    public private(set) var appleLibraryID: String?

    /// True only if we created the Apple counterpart; recorded once, never inferred.
    public private(set) var appleIsOurs: Bool = false

    /// `LibraryOrigin.rawValue`.
    public private(set) var origin: String = LibraryOrigin.kid.rawValue

    public var kid: Kid?

    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntryRecord.playlist)
    public private(set) var entries: [PlaylistEntryRecord] = []

    public init(
        id: UUID = UUID(),
        name: String,
        origin: LibraryOrigin = .kid,
        at: Date = .now
    ) {
        self.id = id
        self.name = name
        self.origin = origin.rawValue
        self.createdAt = at
        self.modifiedAt = at
    }

    // MARK: - Mutation
    // Every mutator here stamps `modifiedAt`, the contract sync merge relies on.

    public func rename(to newName: String, at: Date = .now) {
        name = newName
        modifiedAt = at
    }

    /// Sets both fields together — they're one fact; split, they mean nothing.
    public func linkToAppleLibrary(id appleID: String, createdByUs: Bool, at: Date = .now) {
        appleLibraryID = appleID
        appleIsOurs = createdByUs
        modifiedAt = at
    }

    /// Appends a song; a dup no-ops silently since two taps meant it once.
    @discardableResult
    public func addSong(
        id catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        origin: LibraryOrigin = .kid,
        ancestry: LibraryAncestry = .none,
        at: Date = .now
    ) -> PlaylistEntryRecord? {
        guard catalogID.kind == .song else { return nil }
        guard !entries.contains(where: { $0.catalogID == catalogID.rawValue }) else { return nil }

        let record = PlaylistEntryRecord(
            catalogID: catalogID,
            displayName: displayName,
            artworkURL: artworkURL,
            position: nextPosition,
            origin: origin,
            ancestry: ancestry,
            at: at
        )
        entries.append(record)
        record.playlist = self
        modifiedAt = at
        return record
    }

    /// Tombstones before detaching — once removed, no query can still name the row.
    public func removeSong(_ catalogID: CatalogID, at: Date = .now) {
        // No renumbering. A hole is not a problem — see ``positionGap``.
        if let context = modelContext {
            for row in entries where row.catalogID == catalogID.rawValue {
                Outbox.delete(row, in: context, at: at)
            }
        }
        entries.removeAll { $0.catalogID == catalogID.rawValue }
        modifiedAt = at
    }

    /// Reorders to this sequence; entries missing from it keep their relative spot.
    public func reorder(to order: [CatalogID], at: Date = .now) {
        let rank = Dictionary(
            order.enumerated().map { ($0.element.rawValue, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let sorted = entries.enumerated().sorted { left, right in
            let a = rank[left.element.catalogID] ?? (order.count + left.offset)
            let b = rank[right.element.catalogID] ?? (order.count + right.offset)
            return a < b
        }
        for (index, entry) in sorted.enumerated() {
            entry.element.move(to: index * Self.positionGap, at: at)
        }
        modifiedAt = at
    }

    /// The gap between neighbours, so an insert never touches either.
    ///
    /// **A reversal.** Renumbering after every edit broke under two offline
    /// devices — a merge could leave two entries sharing a slot, unrepaired.
    /// Appending past the max and tiebreaking on `id` survives that merge.
    public static let positionGap = 1024

    /// One gap past the highest, so appending never rewrites a neighbour.
    private var nextPosition: Int {
        (entries.map(\.position).max() ?? -Self.positionGap) + Self.positionGap
    }

    // MARK: - Reading

    public var libraryOrigin: LibraryOrigin? { LibraryOrigin(rawValue: origin) }

    public var handle: PlaylistHandle {
        PlaylistHandle(local: id, appleLibraryID: appleLibraryID)
    }

    /// The value form; order and tiebreak live in `PlaylistEntryRecord.inOrder`.
    public var row: PlaylistRow {
        PlaylistRow(
            handle: handle,
            name: name,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            appleIsOurs: appleIsOurs,
            origin: libraryOrigin ?? .kid,
            entries: entries.sorted(by: PlaylistEntryRecord.inOrder).map(\.row)
        )
    }
}

/// One song in one playlist.
@Model
public final class PlaylistEntryRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// Always a song; no `itemKind` column since nothing else can appear here.
    public private(set) var catalogID: String = ""

    public private(set) var displayName: String = ""
    public private(set) var artworkURL: URL?

    /// Ascending with gaps between neighbours; see `PlaylistRecord.positionGap`.
    public private(set) var position: Int = 0
    public private(set) var addedAt: Date = Date.distantPast

    /// `LibraryOrigin.rawValue`; unreadable falls to `kid`, unlike a dropped favorite.
    public private(set) var origin: String = LibraryOrigin.kid.rawValue

    /// See the same five on ``FavoriteRecord``.
    public private(set) var albumID: String?
    public private(set) var albumName: String?
    public private(set) var artistID: String?
    public private(set) var artistName: String?
    public private(set) var artistArtworkURL: URL?

    public var playlist: PlaylistRecord?

    public init(
        id: UUID = UUID(),
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        position: Int,
        origin: LibraryOrigin = .kid,
        ancestry: LibraryAncestry = .none,
        at: Date = .now
    ) {
        self.id = id
        self.catalogID = catalogID.rawValue
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.position = position
        self.origin = origin.rawValue
        self.addedAt = at
        self.modifiedAt = at
        apply(ancestry)
    }

    /// The typed origin, falling back to `kid`. See ``origin``.
    public var libraryOrigin: LibraryOrigin { LibraryOrigin(rawValue: origin) ?? .kid }

    func move(to newPosition: Int, at: Date = .now) {
        guard position != newPosition else { return }
        position = newPosition
        modifiedAt = at
    }

    /// Lineage top-up; see `FavoriteRecord.record(ancestry:at:)`.
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

extension PlaylistEntryRecord {
    /// `position` then `id`: two offline devices landing on one number still agree.
    static func inOrder(_ a: PlaylistEntryRecord, _ b: PlaylistEntryRecord) -> Bool {
        (a.position, a.id.uuidString) < (b.position, b.id.uuidString)
    }
}

// MARK: - Absorbing a record another device wrote
// Monotonic merge: an absent field in a remote copy must never undo local state.

extension FavoriteRecord {
    func applySync(
        favoritedAt: Date?,
        displayName: String,
        artworkURL: URL?,
        rawOrigin: String?,
        ancestry: LibraryAncestry,
        at: Date
    ) {
        // Earliest wins, so re-adopting on another device can't reshuffle the shelf.
        if let favoritedAt { self.favoritedAt = min(self.favoritedAt, favoritedAt) }
        self.displayName = displayName
        self.artworkURL = artworkURL
        // Precedence enforced here: an arriving origin can never overwrite `kid`.
        if let rawOrigin, let incoming = LibraryOrigin(rawValue: rawOrigin),
            self.libraryOrigin != .kid || incoming == .kid
        {
            self.origin = rawOrigin
        }
        if !ancestry.isEmpty { apply(ancestry) }
        modifiedAt = at
    }
}

extension PlaylistRecord {
    func applySync(
        name: String,
        createdAt: Date?,
        rawOrigin: String?,
        appleLibraryID: String?,
        appleIsOurs: Bool?,
        at: Date
    ) {
        self.name = name
        if let createdAt { self.createdAt = min(self.createdAt, createdAt) }
        if let rawOrigin { self.origin = rawOrigin }
        // Advance-only: a device without the link must not unlink it for others.
        if let appleLibraryID, self.appleLibraryID == nil { self.appleLibraryID = appleLibraryID }
        if let appleIsOurs, appleIsOurs { self.appleIsOurs = true }
        modifiedAt = at
    }
}

extension PlaylistRecord {
    /// Attaches a song built elsewhere. See ``SuggestionRecord/attach(_:)``.
    func attach(_ record: PlaylistEntryRecord) {
        entries.append(record)
        record.playlist = self
    }
}

extension PlaylistEntryRecord {
    func applySync(
        position: Int?,
        addedAt: Date?,
        displayName: String,
        artworkURL: URL?,
        rawOrigin: String?,
        ancestry: LibraryAncestry,
        at: Date
    ) {
        // Position is ordinary state; a later reorder simply wins per `newerRecord`.
        if let position { self.position = position }
        if let addedAt { self.addedAt = min(self.addedAt, addedAt) }
        self.displayName = displayName
        self.artworkURL = artworkURL
        if let rawOrigin { self.origin = rawOrigin }
        if !ancestry.isEmpty { apply(ancestry) }
        modifiedAt = at
    }
}
