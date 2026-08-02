import Foundation
import PolicyEngine
import SwiftData

/// A song, album or artist this kid marked.
///
/// **Never a playlist**: a playlist is not favorited, it is owned. See
/// ``PlaylistRecord``.
///
/// Keyed by `(kid, catalogID, itemKind)` and written as an upsert, so the same
/// favorite arriving twice — tapped twice, or adopted from the Apple Music
/// library while being tapped — collapses to one row. There is no unique
/// constraint doing that work: CloudKit rejects those outright, so the upsert is
/// in ``Kid/addFavorite(id:displayName:artworkURL:origin:at:)`` instead.
///
/// **Not an event.** A retention sweep written against "child data older than 90
/// days" must not reach this table. Plays and searches roll into summaries;
/// favorites are durable user data, deleted only by the kid or with the kid.
@Model
public final class FavoriteRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// Always an Apple Music catalog identifier. Library picks are resolved to
    /// their catalog equivalents before they reach here.
    public private(set) var catalogID: String = ""

    /// `ItemKind.rawValue` — `"song"`, `"album"` or `"artist"`. Part of the
    /// identity, because MusicKit identifiers are only unique within a type.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    /// Copied at write time and never refreshed, so a shelf renders offline and
    /// a delisted item still reads as a name instead of an identifier.
    public private(set) var displayName: String = ""

    /// A reference only. Artwork bytes are never copied into our storage.
    public private(set) var artworkURL: URL?

    public private(set) var favoritedAt: Date = Date.distantPast

    /// `LibraryOrigin.rawValue`.
    public private(set) var origin: String = LibraryOrigin.kid.rawValue

    // MARK: - Ancestry
    //
    // Five flat columns rather than one embedded value, the way `StoredOrigin`
    // is spread across the event tables: SwiftData stores a struct as an opaque
    // blob, and a blob cannot be predicated on. These can be, and a library that
    // grows will want that. See ``LibraryAncestry`` for why the names are copied
    // here at all.

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

    /// Builds a row straight from stored strings, bypassing the typed enums.
    ///
    /// Internal, and the only way to produce a row this version cannot read —
    /// which is what the drop-it path in ``row`` has to be tested against.
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

    /// The upsert half: a second tap refreshes the copied metadata rather than
    /// making a second row.
    ///
    /// `favoritedAt` deliberately does **not** move. It is when the kid said so,
    /// and a shelf ordered most-recent-first should not reshuffle because
    /// something was adopted again on a later read.
    func refresh(
        displayName: String,
        artworkURL: URL?,
        origin: LibraryOrigin,
        ancestry: LibraryAncestry = .none,
        at: Date = .now
    ) {
        self.displayName = displayName
        self.artworkURL = artworkURL
        // A row the kid tapped never degrades to an adopted one. The reverse is
        // allowed: adopting something already on the shelf leaves it the kid's.
        if origin == .kid {
            self.origin = origin.rawValue
        }
        // Only ever an improvement. A second tap while the network is down
        // arrives with nothing resolved, and letting that overwrite a lineage we
        // already hold would empty the artist column for a song the kid liked
        // twice.
        if !ancestry.isEmpty {
            apply(ancestry)
        }
        self.modifiedAt = at
    }

    /// Records lineage learned after the fact.
    ///
    /// The top-up's write. Separate from ``refresh(displayName:artworkURL:origin:ancestry:at:)``
    /// because it is not a second tap and must not touch the copied metadata —
    /// the name on the row is what the kid saw when they kept it.
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

    /// Unreadable is `nil` here rather than a fallback, and the row is dropped
    /// by ``row``. Nothing fails closed on this table: a favorite is not a
    /// permission, so losing one costs a tile and costs safety nothing.
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

/// A playlist the kid owns. Order is the content.
///
/// Not an event, for the same reason ``FavoriteRecord`` is not: these are the
/// records in the whole store with the most work in them, and a retention sweep
/// that reached them would delete a kid's playlists silently, months later.
@Model
public final class PlaylistRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// Free text a child typed. It reaches their Apple Music library and the
    /// parent's report, both of which are worth knowing before the field is
    /// built rather than after.
    public private(set) var name: String = ""

    public private(set) var createdAt: Date = Date.distantPast

    /// The Apple Music library playlist this is the same playlist as.
    ///
    /// `nil` means no counterpart: never created there, or the provider was not
    /// live at the time.
    public private(set) var appleLibraryID: String?

    /// True **only** when this app created the Apple counterpart.
    ///
    /// MusicKit refuses to edit a playlist the app did not create and exposes no
    /// way to ask whether it did. Recorded at creation because it is otherwise
    /// unrecoverable: a playlist read back later is indistinguishable from one
    /// Apple made. Never inferred.
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
    //
    // Every stored property is `private(set)` and changed only through these,
    // which stamp `modifiedAt` — the same contract every other record in this
    // store keeps, and the one an entry-level sync merge will depend on.

    public func rename(to newName: String, at: Date = .now) {
        name = newName
        modifiedAt = at
    }

    /// Records the Apple counterpart, at the one moment it is knowable.
    ///
    /// Takes both fields together because they are one fact. An identifier
    /// without `appleIsOurs` is a playlist we will read back and never dare
    /// edit; `appleIsOurs` without an identifier is nothing at all.
    public func linkToAppleLibrary(id appleID: String, createdByUs: Bool, at: Date = .now) {
        appleLibraryID = appleID
        appleIsOurs = createdByUs
        modifiedAt = at
    }

    /// Appends a song, or does nothing if it is already here.
    ///
    /// Silently, rather than as a failure: a kid adding the same song twice from
    /// two screens meant it once, and an error message about it would be the app
    /// telling them off for something that is not a mistake.
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

    public func removeSong(_ catalogID: CatalogID, at: Date = .now) {
        // No renumbering. A hole is not a problem — see ``positionGap``.
        entries.removeAll { $0.catalogID == catalogID.rawValue }
        modifiedAt = at
    }

    /// Reorders to exactly this sequence of songs.
    ///
    /// Takes the whole order rather than a from/to pair because that is what a
    /// drag hands back after the fact, and because an identifier that is no
    /// longer here — a race with a removal on another screen — then simply does
    /// not appear rather than shifting everything below it by one.
    ///
    /// Anything absent from `order` keeps its relative position at the end, so a
    /// partial order is a reorder rather than a deletion.
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

    /// The space left between two neighbours, so something can be put between
    /// them without touching either.
    ///
    /// **Gaps are the supported state now, and that is a reversal.** This used
    /// to renumber to contiguous integers after every edit, on the reasoning
    /// that two racing edits should produce a consistent order rather than a
    /// hole. Under one writer that held. Under two it is the bug: `renumber`
    /// runs only on the device doing the editing, so after a merge the list has
    /// two entries claiming one slot and a hole where nothing repairs it. It
    /// also rewrote `position` **and** `modifiedAt` on every row on every add,
    /// so adding a fortieth song was forty record updates — on the records
    /// CLAUDE.md names as holding the most of a child's own work, and the ones
    /// with no undo.
    ///
    /// What replaces it is cheaper and survives a merge: append past the
    /// current maximum, never touch a neighbour, and break ties on `id` at read
    /// time so two devices that do land on one number still agree what the
    /// order is. Arbitrary between those two songs, identical everywhere, which
    /// is the property that matters.
    ///
    /// Exhaustion is not a real concern here: a reorder redistributes from zero,
    /// and a kid's playlist would need a thousand insertions between one pair of
    /// songs to close the gap.
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

    /// The value form. Unreadable rows are dropped from `entries` rather than
    /// renumbering around them — the positions stored are still the truth.
    ///
    /// **Sorted on `(position, id)`, and the tiebreak is load-bearing.** Two
    /// devices appending offline compute the same maximum and land on the same
    /// number; without a second key the order between those two songs is
    /// whatever the relationship happens to hand back, which can differ per
    /// device and per launch. The identifier is arbitrary and *identical
    /// everywhere*, which is the property a child's playlist needs.
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

    /// **Always a song.** There is no `itemKind` column because there is no
    /// other kind this can be.
    public private(set) var catalogID: String = ""

    public private(set) var displayName: String = ""
    public private(set) var artworkURL: URL?

    /// Ascending, with room between neighbours. See ``PlaylistRecord/positionGap``
    /// — it used to be contiguous after every edit and deliberately is not now.
    public private(set) var position: Int = 0
    public private(set) var addedAt: Date = Date.distantPast

    /// Who put this song here. `LibraryOrigin.rawValue`.
    ///
    /// Without it a song a parent placed on a child's shelf is indistinguishable
    /// from one the child chose, and *"you added 4 of these 12"* is a migration
    /// rather than a caption.
    ///
    /// **Falls back to `kid` on an unreadable value rather than dropping the
    /// row**, deliberately unlike ``FavoriteRecord/row``: a dropped entry
    /// silently shortens a playlist a child built, which is worse than one row
    /// attributed to the commonest case. The default is `kid` for the same
    /// reason — it is the honest answer for the overwhelming majority of rows
    /// written before the column existed, and the precedence rule
    /// (`kid` > `parent` > `appleLibrary`) already says a row the child chose
    /// never degrades.
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

    /// Records lineage learned after the fact. See ``FavoriteRecord/record(ancestry:at:)``.
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
    /// Deterministic order for a playlist's songs.
    ///
    /// `position` first, `id` to break a tie. The tiebreak exists because two
    /// devices appending offline compute the same maximum and land on the same
    /// number — see ``PlaylistRecord/positionGap``. Without it the order between
    /// those two songs is whatever the relationship hands back, which can differ
    /// per device and per launch; with it the answer is arbitrary between them
    /// and the same everywhere.
    static func inOrder(_ a: PlaylistEntryRecord, _ b: PlaylistEntryRecord) -> Bool {
        (a.position, a.id.uuidString) < (b.position, b.id.uuidString)
    }
}

// MARK: - Absorbing a record another device wrote
//
// In this file so `private(set)` stays exactly as strict as it was, and
// monotonic for the reason the others are: a caller handing `apply` a raw
// remote copy must not be able to use an *absence* to undo something. See
// ``SyncApply``.

extension FavoriteRecord {
    func applySync(
        favoritedAt: Date?,
        displayName: String,
        artworkURL: URL?,
        rawOrigin: String?,
        ancestry: LibraryAncestry,
        at: Date
    ) {
        // Earliest wins. A shelf ordered most-recent-first must not reshuffle
        // because the same favorite was adopted again on another device.
        if let favoritedAt { self.favoritedAt = min(self.favoritedAt, favoritedAt) }
        self.displayName = displayName
        self.artworkURL = artworkURL
        // The precedence rule lives in one place and this is not it: a row the
        // child chose never degrades, so an arriving `appleLibrary` or `parent`
        // origin cannot overwrite `kid`.
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
        // Advance only: a device that has not seen the link carries nothing
        // here, and that absence must not unlink a playlist from the account's
        // own library.
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
        // Position is ordinary mutable state — a reorder is a real edit and the
        // later one wins, which is what `newerRecord` already decided upstream.
        if let position { self.position = position }
        if let addedAt { self.addedAt = min(self.addedAt, addedAt) }
        self.displayName = displayName
        self.artworkURL = artworkURL
        if let rawOrigin { self.origin = rawOrigin }
        if !ancestry.isEmpty { apply(ancestry) }
        modifiedAt = at
    }
}
