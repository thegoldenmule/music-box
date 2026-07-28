import Foundation
import PolicyEngine
import SwiftData

/// One kid, their walls, and their history.
///
/// Sandbox level is here rather than on ``Family`` because it is set per kid.
/// A seven-year-old and a twelve-year-old in the same house do not get the same
/// catalog.
@Model
public final class Kid {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast
    public private(set) var name: String = ""

    /// Stored explicitly. **Never read from a global default at evaluation
    /// time** — if a constant were consulted instead, changing a recommended
    /// default in a later release would silently change what every existing kid
    /// can reach.
    ///
    /// The schema defaults below exist only because CloudKit requires every
    /// attribute to have one; the initializer always supplies both, so no real
    /// row ever falls back to them. They are the *most restrictive* values
    /// rather than the recommended ones, so that if one ever were consulted it
    /// would fail closed.
    public private(set) var mode: SandboxMode = SandboxMode.allowOnly
    public private(set) var unratedBehavior: UnratedBehavior = UnratedBehavior.block

    public var family: Family?

    @Relationship(deleteRule: .cascade, inverse: \PolicyEntryRecord.kid)
    public private(set) var entries: [PolicyEntryRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \SearchEventRecord.kid)
    public private(set) var searches: [SearchEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \PlayEventRecord.kid)
    public private(set) var plays: [PlayEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \BlockEventRecord.kid)
    public private(set) var blocks: [BlockEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \WeeklySummaryRecord.kid)
    public private(set) var summaries: [WeeklySummaryRecord] = []

    // The kid's own library. Not events, and deliberately not touched by
    // ``deleteHistory()`` — see the note there.

    @Relationship(deleteRule: .cascade, inverse: \FavoriteRecord.kid)
    public private(set) var favorites: [FavoriteRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \PlaylistRecord.kid)
    public private(set) var playlists: [PlaylistRecord] = []

    public init(
        id: UUID = UUID(),
        name: String,
        mode: SandboxMode,
        unratedBehavior: UnratedBehavior = .block,
        at: Date = .now
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.unratedBehavior = unratedBehavior
        self.modifiedAt = at
    }

    // MARK: - Mutation
    //
    // Every stored property is `private(set)` and changed only through these,
    // which stamp `modifiedAt`. The invariant is that every record carries the
    // time it last changed; leaving the properties writable would make that a
    // thing each caller had to remember, and sync merging later depends on it.

    public func rename(to newName: String, at: Date = .now) {
        name = newName
        modifiedAt = at
    }

    public func setMode(_ newMode: SandboxMode, at: Date = .now) {
        mode = newMode
        modifiedAt = at
    }

    public func setUnratedBehavior(_ behavior: UnratedBehavior, at: Date = .now) {
        unratedBehavior = behavior
        modifiedAt = at
    }

    // MARK: - Lists
    //
    // Callers must `save()` and surface a failure. A parent who taps deny and
    // gets silence must not be left believing the deny landed. This is the
    // opposite of event logging, which is fire-and-forget.

    @discardableResult
    public func addEntry(
        kind: PolicyEntry.Kind,
        id catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        addedBy: String? = nil,
        at: Date = .now
    ) -> PolicyEntryRecord {
        let record = PolicyEntryRecord(
            kind: kind,
            catalogID: catalogID,
            displayName: displayName,
            artworkURL: artworkURL,
            addedBy: addedBy,
            at: at
        )
        attach(record, at: at)
        return record
    }

    func attach(_ record: PolicyEntryRecord, at: Date = .now) {
        entries.append(record)
        record.kid = self
        modifiedAt = at
    }

    public func removeEntry(_ record: PolicyEntryRecord, at: Date = .now) {
        entries.removeAll { $0.id == record.id }
        modifiedAt = at
    }

    // MARK: - Events
    //
    // Attaching an event deliberately does **not** stamp `modifiedAt`. That
    // field describes the kid record itself — their name, mode, unrated
    // behavior — and is what an entry-level merge will compare when two
    // parents' devices reconcile. Bumping it on every play would make a child
    // listening to music look like a parent editing settings, and would churn
    // the one record sync most needs to be quiet.

    func attach(_ record: SearchEventRecord) {
        searches.append(record)
        record.kid = self
    }

    func attach(_ record: PlayEventRecord) {
        plays.append(record)
        record.kid = self
    }

    func attach(_ record: BlockEventRecord) {
        blocks.append(record)
        record.kid = self
    }

    func attach(_ record: WeeklySummaryRecord) {
        summaries.append(record)
        record.kid = self
    }

    // MARK: - The kid's library
    //
    // Awaited and surfaced by the caller, like the lists above and unlike the
    // events below: a heart that fills over a write that did not land is a lie.
    //
    // These deliberately do **not** stamp `modifiedAt`. That field describes the
    // kid record itself — their name, mode, unrated behavior — and is what an
    // entry-level sync merge compares. A kid favoriting forty songs is not a
    // parent editing settings, and should not churn the one record sync most
    // needs to be quiet.

    /// Adds a favorite, or refreshes the one already there.
    ///
    /// An upsert rather than an insert, because the same favorite can arrive
    /// twice — tapped twice, or adopted from the Apple Music library while being
    /// tapped. Two rows for one heart would show the same tile twice and take
    /// two taps to undo.
    ///
    /// Refuses a playlist: a playlist is not favorited, it is owned.
    @discardableResult
    public func addFavorite(
        id catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        origin: LibraryOrigin = .kid,
        at: Date = .now
    ) -> FavoriteRecord? {
        guard catalogID.kind != .playlist else { return nil }

        if let existing = favoriteRecord(for: catalogID) {
            existing.refresh(
                displayName: displayName,
                artworkURL: artworkURL,
                origin: origin,
                at: at
            )
            return existing
        }

        let record = FavoriteRecord(
            catalogID: catalogID,
            displayName: displayName,
            artworkURL: artworkURL,
            origin: origin,
            at: at
        )
        attach(record)
        return record
    }

    func attach(_ record: FavoriteRecord) {
        favorites.append(record)
        record.kid = self
    }

    /// Removes every row for this item.
    ///
    /// Every, not the first: nothing in the schema stops two rows existing —
    /// CloudKit rejects unique constraints — and leaving one behind would look
    /// like the heart refused to empty.
    public func removeFavorite(_ catalogID: CatalogID) {
        favorites.removeAll {
            $0.catalogID == catalogID.rawValue && $0.itemKind == catalogID.kind.rawValue
        }
    }

    public func favoriteRecord(for catalogID: CatalogID) -> FavoriteRecord? {
        favorites.first {
            $0.catalogID == catalogID.rawValue && $0.itemKind == catalogID.kind.rawValue
        }
    }

    @discardableResult
    public func addPlaylist(
        named name: String,
        origin: LibraryOrigin = .kid,
        at: Date = .now
    ) -> PlaylistRecord {
        let record = PlaylistRecord(name: name, origin: origin, at: at)
        attach(record)
        return record
    }

    func attach(_ record: PlaylistRecord) {
        playlists.append(record)
        record.kid = self
    }

    public func removePlaylist(_ record: PlaylistRecord) {
        playlists.removeAll { $0.id == record.id }
    }

    public func playlistRecord(for local: UUID) -> PlaylistRecord? {
        playlists.first { $0.id == local }
    }

    // MARK: - History

    /// Deletes this kid's history and nothing else.
    ///
    /// Summaries go too: one outliving the events it was derived from is a
    /// record the parent asked us to destroy. Lists, mode and unrated behavior
    /// stay — curation is not history, and a parent deleting a month of logs is
    /// not asking to rebuild their allow list.
    ///
    /// **Favorites and playlists stay for the same reason and then some.** They
    /// are not events: they are the records in this store with the most of a
    /// child's own work in them, and nothing about "delete my history" asks for
    /// a playlist to disappear. Whatever retention window is eventually chosen
    /// for event data must exempt them too.
    public func deleteHistory(at: Date = .now) {
        searches.removeAll()
        plays.removeAll()
        blocks.removeAll()
        summaries.removeAll()
        modifiedAt = at
    }
}
