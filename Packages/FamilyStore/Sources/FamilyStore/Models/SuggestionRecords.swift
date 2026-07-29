import Foundation
import PolicyEngine
import SwiftData

/// Something a parent put in front of their kid.
///
/// **A suggestion widens reach.** Non-dismissed rows are folded into the kid's
/// policy as allows by ``Kid/buildPolicy()``, so a suggested item is reachable at
/// every sandbox level. That is the whole point of the feature — the rest of the
/// parent's surface is about bounding what a kid gets to, and this is the one
/// that hands them something.
///
/// It is the reason two rules below are the way they are:
///
/// - **Dismissal drops the allow, not just the tile.** A kept allow on a passed-on
///   suggestion would be an *invisible* one: at level 2 a per-item allow overrides
///   the rating check, so a dismissed explicit song would stay playable from
///   search forever with no screen in the app saying so. The allow list would not
///   list it and this list would show it greyed out. The invariant is that
///   everything widening reach appears on exactly one visible screen.
/// - **An unreadable row fails by omission, not by denial.** ``PolicyEntryRecord``
///   does the opposite — a row it cannot read becomes a deny — because dropping a
///   real deny silently unblocks something a parent refused. Copying that here
///   would be backwards: a deny wins in every mode, so a corrupt *suggestion*
///   would become a family-wide block, which is strictly worse than the failure
///   the rule exists to prevent. Suggestions are additive, so their failure mode
///   is additive too: drop it, report it.
///
/// **Not an event, and not the kid's library either.** A retention sweep must not
/// reach this table — a parent has not withdrawn a suggestion by clearing logs —
/// and neither must anything that reads what the *kid* kept. Favoriting something
/// off this shelf writes an ordinary ``FavoriteRecord`` and leaves this row alone.
@Model
public final class SuggestionRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// The Apple Music catalog identifier, or `nil` for a snapshot playlist.
    ///
    /// `nil` is a supported state on exactly one kind of row. See
    /// ``SuggestionTarget/snapshotPlaylist(local:)`` for why a parent's own
    /// playlist has no identifier to put here, and ``target`` for the read that
    /// refuses to make sense of any other row missing one.
    public private(set) var catalogID: String?

    /// `ItemKind.rawValue`. Part of the identity, because MusicKit identifiers
    /// are only unique within a type.
    public private(set) var itemKind: String = ItemKind.album.rawValue

    /// Copied at write time and never refreshed, so the shelf renders offline
    /// and a delisted item still reads as a name instead of an identifier.
    public private(set) var displayName: String = ""

    /// The artist under an album, the curator under a playlist. Copied for the
    /// same reason and at the same moment.
    public private(set) var subtitle: String?

    /// A reference only. Artwork bytes are never copied into our storage.
    public private(set) var artworkURL: URL?

    public private(set) var suggestedAt: Date = Date.distantPast

    /// Ascending and monotonic within a kid; the shelf reads it descending.
    ///
    /// One past the highest at insert, so adding a suggestion never rewrites the
    /// rows around it. Shifting fifty rows to make room at position zero would
    /// stamp fifty `modifiedAt`s, which is the sync churn this store spends
    /// effort avoiding everywhere else.
    public private(set) var position: Int = 0

    /// When the kid passed on it. `nil` while it is live.
    public private(set) var dismissedAt: Date?

    /// A parent's one line about why they picked it. Shown to the kid.
    ///
    /// Free text an adult typed that a child reads — worth knowing about before
    /// the field exists rather than after.
    public private(set) var note: String?

    public private(set) var addedBy: String?

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
        at: Date = .now
    ) {
        self.id = id
        switch target {
        case .catalog(let catalogID):
            self.catalogID = catalogID.rawValue
            self.itemKind = catalogID.kind.rawValue
        case .snapshotPlaylist(let local):
            // The row's own identity *is* the handle, the way
            // `PlaylistRecord.handle` is built from its `id`. A second column
            // holding the same UUID would be one more thing that can disagree.
            self.id = local
            self.catalogID = nil
            self.itemKind = ItemKind.playlist.rawValue
        }
        self.displayName = displayName
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.position = position
        self.note = note
        self.addedBy = addedBy
        self.suggestedAt = at
        self.modifiedAt = at
    }

    /// Builds a row straight from stored strings, bypassing the typed enums.
    ///
    /// Internal, and the only way to produce a row this version cannot read —
    /// which is what the drop-it path in ``row`` and the fold in
    /// ``Kid/buildPolicy()`` have to be tested against.
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

    /// The upsert half: suggesting something already on the shelf refreshes the
    /// copied metadata rather than making a second row.
    ///
    /// `suggestedAt` and `position` deliberately do **not** move here. Suggesting
    /// something that is already live is usually a parent forgetting they did,
    /// and reshuffling the shelf under a kid for that is worse than doing
    /// nothing. ``restore(position:at:)`` is the case where the order *should*
    /// change, and it is a separate call because it is a separate intention.
    func refresh(
        displayName: String,
        subtitle: String?,
        artworkURL: URL?,
        note: String?,
        at: Date = .now
    ) {
        self.displayName = displayName
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        // Only ever set, never cleared by a refresh: a re-suggestion that came
        // through a surface without a note field must not silently erase the
        // sentence a parent wrote on the one that had it.
        if let note { self.note = note }
        self.modifiedAt = at
    }

    /// The kid passed on it.
    ///
    /// Stamps `modifiedAt` even though it is a kid's action rather than a
    /// parent's — the other kid-side writes in this store deliberately do not.
    /// The difference is that this one changes what the child can reach, and
    /// `modifiedAt` is what a sync merge compares. A dismissal that lost a race
    /// with another device would put the item back.
    public func dismiss(at: Date = .now) {
        guard dismissedAt == nil else { return }
        dismissedAt = at
        modifiedAt = at
    }

    /// The parent offered it again.
    ///
    /// Moves it to the front, unlike ``refresh(displayName:subtitle:artworkURL:note:at:)``:
    /// re-suggesting something a kid passed on is a deliberate second act, and it
    /// is worth nothing if the kid never sees it.
    public func restore(position newPosition: Int, at: Date = .now) {
        dismissedAt = nil
        position = newPosition
        suggestedAt = at
        modifiedAt = at
    }

    public func setNote(_ newNote: String?, at: Date = .now) {
        note = newNote
        modifiedAt = at
    }

    /// Appends a resolved song, or does nothing if it is already here.
    ///
    /// Ancestry is not optional here the way it is elsewhere — see
    /// ``SuggestionEntryRecord``.
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

    /// What this points at, or `nil` for a row this version cannot read.
    ///
    /// A missing `catalogID` is only meaningful on a playlist. Anything else
    /// without one is unreadable and dropped — never guessed at, and never
    /// turned into a deny.
    public var target: SuggestionTarget? {
        guard let kind = ItemKind(rawValue: itemKind) else { return nil }
        if let catalogID, !catalogID.isEmpty {
            return .catalog(CatalogID(kind, catalogID))
        }
        guard kind == .playlist else { return nil }
        return .snapshotPlaylist(local: id)
    }

    public var isDismissed: Bool { dismissedAt != nil }

    /// Every catalog identifier this suggestion vouches for.
    ///
    /// What ``Kid/buildPolicy()`` folds in as allows, and empty for a dismissed
    /// row. A playlist contributes its own identifier *and* every resolved
    /// track: nothing in this app puts a playlist into a track's lineage, so an
    /// allow on the playlist alone reaches the container and none of its
    /// contents.
    public var allowedIDs: [CatalogID] {
        guard dismissedAt == nil, let target else { return [] }
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
            note: note,
            addedBy: addedBy,
            entries: entries.sorted { $0.position < $1.position }.map(\.row)
        )
    }
}

/// One resolved song inside a suggested playlist.
///
/// Structurally a ``PlaylistEntryRecord`` and deliberately not one: that table is
/// the kid's own work and is read back by ``MergedLibrary``, and a suggestion
/// landing in it would put the parent's picks on the kid's shelf — the one thing
/// this feature must not do. The value form *is* shared: ``PlaylistEntryRow``
/// says "a song, in order, with its metadata copied down," which is exactly what
/// this is, and two identical structs would be two places to remember.
@Model
public final class SuggestionEntryRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    /// **Always a song.** There is no `itemKind` column because there is no
    /// other kind this can be.
    public private(set) var catalogID: String = ""

    public private(set) var displayName: String = ""
    public private(set) var artworkURL: URL?

    /// 0-based, in the order the parent's playlist had them.
    public private(set) var position: Int = 0
    public private(set) var addedAt: Date = Date.distantPast

    // MARK: - Ancestry
    //
    // The same five flat columns as ``FavoriteRecord``, and here they are closer
    // to load-bearing than anywhere else they appear.
    //
    // `Session.queuedVerdict` opens with `guard !item.ancestors.isEmpty` and
    // returns `.unknown` otherwise, and `KidPlayerModel` refuses to queue
    // anything `.unknown`. A snapshot row storing only an identifier and a name
    // would therefore cost **every track in a suggested playlist its gapless
    // join** — forty tracks, forty gaps.
    //
    // It matters for safety too, and more quietly: a bare song id that is in the
    // allow set evaluates `.allowed` at level 2 with a deny on its artist never
    // consulted, because `firstDenied` has no ancestors to walk. Since a
    // suggestion *is* an allow, that is not hypothetical here.
    //
    // None of it costs a request. `resolveToCatalog` already asks for
    // `[.albums, .artists]` and currently throws the answer away.

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
