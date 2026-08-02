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
    /// **A cache, and never the authority. Do not read these.**
    ///
    /// ``effectiveMode`` and ``effectiveUnratedBehavior`` are the answer;
    /// `SandboxSettingRecord` is where the decision lives. These two columns
    /// remain for exactly two reasons, and neither is "convenience":
    ///
    /// 1. They are the answer for a store written before decisions existed,
    ///    where the column *was* the decision. That is what let those fields
    ///    move without a custom migration over a family's live curation.
    /// 2. A build that predates the decision table still reads them, so
    ///    refreshing them on every write keeps two versions in one household
    ///    agreeing rather than diverging.
    ///
    /// Reading them directly is a bug that will not show up on one device: a
    /// decision arriving from another device writes a row, and this copy goes
    /// stale until something happens to touch it.
    ///
    /// They cannot be renamed to something that says so — a column rename is a
    /// migration, and these carry every existing family's sandbox level.
    public private(set) var mode: SandboxMode = SandboxMode.allowOnly
    public private(set) var unratedBehavior: UnratedBehavior = UnratedBehavior.block

    /// The Apple Account that *is* this child, when they have one of their own
    /// under Family Sharing. `nil` for every kid on a parent's account, which is
    /// the commoner shape and the one the device binding covers alone.
    ///
    /// A column on the existing `Kid` rather than a second kid record per
    /// account, and that is the whole point of it: a child who gets their own
    /// Apple Account at nine becomes a one-field write instead of a data
    /// migration, and every favorite, playlist and week of history stays exactly
    /// where it is.
    ///
    /// **This is the half of "tied to Apple IDs" that may never fire.** Whether
    /// an under-13 account can participate in a CloudKit share at all is
    /// unverified, and `CKAccountStatus.restricted` — documented as what
    /// parental controls produce — is a plausible steady state on precisely the
    /// device this is for. If the probe comes back negative, every kid device
    /// runs under a parent's account, the device binding is the only key, and
    /// this stays nil forever. It is one column either way.
    public private(set) var boundAccountRecordName: String?

    public var family: Family?

    @Relationship(deleteRule: .cascade, inverse: \PolicyEntryRecord.kid)
    public private(set) var entries: [PolicyEntryRecord] = []

    /// Every decision anyone has made about how wide this child's sandbox is.
    ///
    /// Append-only, and the authority for ``effectiveMode`` and
    /// ``effectiveUnratedBehavior``. Empty on every store that predates the
    /// table, which is what makes the cached columns the answer there.
    @Relationship(deleteRule: .cascade, inverse: \SandboxSettingRecord.kid)
    public private(set) var sandboxSettings: [SandboxSettingRecord] = []

    /// What a parent has put in front of this kid.
    ///
    /// Grouped with ``entries`` rather than with the library below, because a
    /// live suggestion is folded into the policy as an allow by
    /// ``buildPolicy()`` — it is a thing that changes what the kid can reach,
    /// which is what the lists are and what the library deliberately is not.
    @Relationship(deleteRule: .cascade, inverse: \SuggestionRecord.kid)
    public private(set) var suggestions: [SuggestionRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \SearchEventRecord.kid)
    public private(set) var searches: [SearchEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \PlayEventRecord.kid)
    public private(set) var plays: [PlayEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \BlockEventRecord.kid)
    public private(set) var blocks: [BlockEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \VisitEventRecord.kid)
    public private(set) var visits: [VisitEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \WeeklySummaryRecord.kid)
    public private(set) var summaries: [WeeklySummaryRecord] = []

    /// The Recent shelf, derived from ``visits``.
    ///
    /// A projection rather than a record of anything — see ``RecentTrailRecord``
    /// — which is why it sits apart from the event relationships above and is
    /// listed separately everywhere they are handled together.
    @Relationship(deleteRule: .cascade, inverse: \RecentTrailRecord.kid)
    public private(set) var recentTrail: [RecentTrailRecord] = []

    // The kid's own library. Not events, and deliberately not touched by
    // ``deleteHistory()`` — see the note there.

    @Relationship(deleteRule: .cascade, inverse: \FavoriteRecord.kid)
    public private(set) var favorites: [FavoriteRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \PlaylistRecord.kid)
    public private(set) var playlists: [PlaylistRecord] = []

    /// What the library contains because of what is in ``favorites`` — see
    /// ``LibraryIndexRecord``.
    ///
    /// A projection, like ``recentTrail``, but one that follows the library
    /// rather than the event log: it survives ``deleteHistory(at:)`` and goes
    /// with ``deleteEverything(at:)``, because its source does.
    @Relationship(deleteRule: .cascade, inverse: \LibraryIndexRecord.kid)
    public private(set) var libraryIndex: [LibraryIndexRecord] = []

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

    /// Records a decision about the sandbox level, **and** refreshes the cache.
    ///
    /// Both halves matter. The decision row is the authority and is what stops a
    /// concurrent rename from swallowing a tightening; the column keeps every
    /// existing reader working and is what a store with no decision rows falls
    /// back to. Nothing may read `mode` directly — use ``effectiveMode``.
    public func setMode(
        _ newMode: SandboxMode,
        decidedByGrownUpID: UUID? = nil,
        decidedByAccountRecordName: String? = nil,
        originatingDeviceID: UUID? = nil,
        at: Date = .now
    ) {
        decide(
            .mode,
            rawValue: newMode.rawValue,
            decidedByGrownUpID: decidedByGrownUpID,
            decidedByAccountRecordName: decidedByAccountRecordName,
            originatingDeviceID: originatingDeviceID,
            at: at
        )
        mode = newMode
        modifiedAt = at
    }

    public func setUnratedBehavior(
        _ behavior: UnratedBehavior,
        decidedByGrownUpID: UUID? = nil,
        decidedByAccountRecordName: String? = nil,
        originatingDeviceID: UUID? = nil,
        at: Date = .now
    ) {
        decide(
            .unratedBehavior,
            rawValue: behavior.rawValue,
            decidedByGrownUpID: decidedByGrownUpID,
            decidedByAccountRecordName: decidedByAccountRecordName,
            originatingDeviceID: originatingDeviceID,
            at: at
        )
        unratedBehavior = behavior
        modifiedAt = at
    }

    private func decide(
        _ key: SandboxSettingKey,
        rawValue: String,
        decidedByGrownUpID: UUID?,
        decidedByAccountRecordName: String?,
        originatingDeviceID: UUID?,
        at: Date
    ) {
        attach(
            SandboxSettingRecord(
                key: key,
                rawValue: rawValue,
                decidedByAccountRecordName: decidedByAccountRecordName,
                decidedByGrownUpID: decidedByGrownUpID,
                originatingDeviceID: originatingDeviceID,
                at: at
            )
        )
    }

    /// Attaches a decision built elsewhere.
    ///
    /// Internal because the supported way to make one is ``setMode(_:decidedByGrownUpID:decidedByAccountRecordName:originatingDeviceID:at:)``,
    /// which also refreshes the cache. The caller that needs this is a test
    /// writing a raw value *this build cannot read* — which is the case the
    /// resolution rule has to be right about and which no public API can
    /// produce.
    func attach(_ record: SandboxSettingRecord) {
        sandboxSettings.append(record)
        record.kid = self
    }

    // MARK: - What is actually in force

    /// The sandbox level in force, resolved from the decisions.
    ///
    /// **The only thing that may decide what a child can reach.** Falls back to
    /// the cached ``mode`` column when there are no readable decisions — which
    /// is every store written before decisions existed, and is the right answer
    /// for one: the column *was* the decision there.
    ///
    /// That fallback is also why this change needed no migration. The old column
    /// is still the source of truth for old data, so nothing had to be rewritten
    /// and no schema version had to be frozen.
    public var effectiveMode: SandboxMode {
        SandboxSettingResolution.resolve(
            sandboxSettings,
            key: .mode,
            parse: SandboxMode.init(rawValue:),
            narrower: SandboxSettingResolution.narrower
        ) ?? mode
    }

    /// What an unrated item is treated as, resolved from the decisions.
    /// See ``effectiveMode``.
    public var effectiveUnratedBehavior: UnratedBehavior {
        SandboxSettingResolution.resolve(
            sandboxSettings,
            key: .unratedBehavior,
            parse: UnratedBehavior.init(rawValue:),
            narrower: SandboxSettingResolution.narrower
        ) ?? unratedBehavior
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
        addedByName: String? = nil,
        at: Date = .now
    ) -> PolicyEntryRecord {
        // **Re-asserts rather than duplicating.** (kind, itemKind, catalogID) is
        // this row's natural key, and adding the same thing twice — a parent
        // re-denying an artist they denied and then withdrew, or two parents
        // denying the same one — has to land on one row. Two rows with one key
        // is how a retraction gets lost: withdrawing "the" deny leaves its twin
        // standing, and the screen shows one entry either way.
        if let existing = entries.first(where: {
            $0.kind == kind.rawValue
                && $0.itemKind == catalogID.kind.rawValue
                && $0.catalogID == catalogID.rawValue
        }) {
            existing.reassert(at: at)
            modifiedAt = at
            return existing
        }

        let record = PolicyEntryRecord(
            kind: kind,
            catalogID: catalogID,
            displayName: displayName,
            artworkURL: artworkURL,
            addedBy: addedBy,
            addedByName: addedByName,
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

    /// Takes a row off the list by **retracting** it, not by deleting it.
    ///
    /// This replaces a delete, and the reasoning is worth keeping because it
    /// moved twice. Originally this was `entries.removeAll { }` alone, which
    /// nulls the inverse and leaves the row where no query can reach it — every
    /// query here is `kid?.id == kidID` — so a parent who removed a deny watched
    /// it vanish from the screen while it went on being a deny for nobody. The
    /// fix for that was to delete through the context, and that was right for a
    /// store with one writer.
    ///
    /// It is wrong for a store with two. **A deleted row leaves nothing to
    /// enumerate**, so the removal can never be exported, and a co-parent's
    /// device keeps the entry forever. The retraction *is* the tombstone, and it
    /// is what makes two parents editing one list offline resolve without
    /// arbitration — see ``PolicyEntryRecord/retractedAt``.
    ///
    /// The row stays attached to the kid, so it is visible to every query and to
    /// the admin; ``buildPolicy()`` is what filters it out of the policy.
    public func removeEntry(_ record: PolicyEntryRecord, at: Date = .now) {
        record.retract(at: at)
        modifiedAt = at
    }

    /// Every entry that is currently part of the policy.
    public var liveEntries: [PolicyEntryRecord] { entries.filter(\.isLive) }

    // MARK: - Suggestions
    //
    // Awaited and surfaced like the lists above, and for a stronger version of
    // the same reason: these grant reach. A parent who suggests an album and
    // gets silence must not be left believing their kid can now play it.
    //
    // They stamp `modifiedAt` — a parent curating is exactly what that field is
    // for — and so does dismissal, which is the one kid-side write in this store
    // that does. See ``SuggestionRecord/dismiss(at:)``.

    /// Suggests something, or refreshes what is already there.
    ///
    /// An upsert, like ``addFavorite(id:displayName:artworkURL:origin:ancestry:at:)``:
    /// the same album suggested twice is one shelf tile, not two.
    ///
    /// The two collision cases are deliberately different. A **live** row is
    /// refreshed in place and keeps its position — suggesting something already
    /// on the shelf is usually a parent forgetting they did, and reshuffling a
    /// kid's screen for that helps nobody. A **dismissed** row is restored to the
    /// front, because offering something again after a kid passed on it is a
    /// second act and is worth nothing if they never see it.
    @discardableResult
    public func addSuggestion(
        target: SuggestionTarget,
        displayName: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        note: String? = nil,
        addedBy: String? = nil,
        addedByName: String? = nil,
        at: Date = .now
    ) -> SuggestionRecord {
        if let existing = suggestionRecord(for: target) {
            existing.refresh(
                displayName: displayName,
                subtitle: subtitle,
                artworkURL: artworkURL,
                note: note,
                addedBy: addedBy,
                addedByName: addedByName,
                at: at
            )
            if existing.isDismissed {
                existing.restore(position: nextSuggestionPosition, at: at)
            }
            modifiedAt = at
            return existing
        }

        let record = SuggestionRecord(
            target: target,
            displayName: displayName,
            subtitle: subtitle,
            artworkURL: artworkURL,
            position: nextSuggestionPosition,
            note: note,
            addedBy: addedBy,
            addedByName: addedByName,
            at: at
        )
        attach(record, at: at)
        return record
    }

    /// Rewrites the copied name on everything this grown-up added.
    ///
    /// Driven by ``Family/renameGrownUp(_:to:at:)``, which is where the reasoning
    /// for correcting a write-time copy lives. Matches on the attribution and
    /// never on the name — two grown-ups may share one, and a rename must not
    /// reach the other's rows.
    func rewriteAttribution(of attribution: String, to newName: String, at: Date = .now) {
        for record in suggestions where record.addedBy == attribution {
            record.rewriteAddedByName(to: newName, at: at)
        }
        for record in entries where record.addedBy == attribution {
            record.rewriteAddedByName(to: newName, at: at)
        }
    }

    func attach(_ record: SuggestionRecord, at: Date = .now) {
        suggestions.append(record)
        record.kid = self
        modifiedAt = at
    }

    /// One past the highest in use. See ``SuggestionRecord/position``.
    private var nextSuggestionPosition: Int {
        (suggestions.map(\.position).max() ?? -1) + 1
    }

    /// The parent withdrew it. Gone, along with the reach it granted.
    ///
    /// Deletes through the context rather than only detaching — `removeAll()` on
    /// a relationship leaves the row on disk where no query can see it. See
    /// ``delete(_:)``.
    public func removeSuggestion(_ record: SuggestionRecord, at: Date = .now) {
        delete([record])
        suggestions.removeAll { $0.id == record.id }
        modifiedAt = at
    }

    /// The kid passed on it. The row stays; the allow does not.
    public func dismissSuggestion(_ record: SuggestionRecord, at: Date = .now) {
        record.dismiss(at: at)
        modifiedAt = at
    }

    /// The parent offered it again, moving it back to the front of the shelf.
    public func restoreSuggestion(_ record: SuggestionRecord, at: Date = .now) {
        record.restore(position: nextSuggestionPosition, at: at)
        modifiedAt = at
    }

    public func suggestionRecord(for target: SuggestionTarget) -> SuggestionRecord? {
        switch target {
        case .catalog(let catalogID):
            return suggestions.first {
                $0.catalogID == catalogID.rawValue && $0.itemKind == catalogID.kind.rawValue
            }
        case .snapshotPlaylist(let local):
            return suggestions.first { $0.id == local && $0.catalogID == nil }
        }
    }

    /// Live suggestions, newest first. What the shelf draws.
    ///
    /// Unreadable rows are dropped rather than denied — see ``SuggestionRecord``.
    public var liveSuggestions: [SuggestionRow] {
        suggestions
            .filter { !$0.isDismissed }
            .sorted { $0.position > $1.position }
            .compactMap(\.row)
    }

    /// What the kid passed on, most recently suggested first. The parent's side
    /// of the shelf, and the only place a dismissal is visible.
    public var dismissedSuggestions: [SuggestionRow] {
        suggestions
            .filter(\.isDismissed)
            .sorted { $0.position > $1.position }
            .compactMap(\.row)
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

    func attach(_ record: VisitEventRecord) {
        visits.append(record)
        record.kid = self
    }

    func attach(_ record: RecentTrailRecord) {
        recentTrail.append(record)
        record.kid = self
    }

    func remove(_ record: RecentTrailRecord) {
        recentTrail.removeAll { $0.id == record.id }
    }

    func clearRecentTrail() {
        recentTrail.removeAll()
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
        ancestry: LibraryAncestry = .none,
        at: Date = .now
    ) -> FavoriteRecord? {
        guard catalogID.kind != .playlist else { return nil }

        if let existing = favoriteRecord(for: catalogID) {
            existing.refresh(
                displayName: displayName,
                artworkURL: artworkURL,
                origin: origin,
                ancestry: ancestry,
                at: at
            )
            return existing
        }

        let record = FavoriteRecord(
            catalogID: catalogID,
            displayName: displayName,
            artworkURL: artworkURL,
            origin: origin,
            ancestry: ancestry,
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
    /// Removes every row for this item, and everything it brought in with it.
    ///
    /// The index goes too, and has to go here rather than in a caller: a favorite
    /// removed without it leaves an artist's thousand tracks in the library with
    /// nothing left that names them, unreachable from any screen that could
    /// clear them and invisible to a parent looking at what is kept.
    public func removeFavorite(_ catalogID: CatalogID) {
        favorites.removeAll {
            $0.catalogID == catalogID.rawValue && $0.itemKind == catalogID.kind.rawValue
        }
        removeIndex(from: catalogID)
    }

    public func favoriteRecord(for catalogID: CatalogID) -> FavoriteRecord? {
        favorites.first {
            $0.catalogID == catalogID.rawValue && $0.itemKind == catalogID.kind.rawValue
        }
    }

    // MARK: - The library index

    /// Adds to what a source has already written, without disturbing it.
    ///
    /// **Append and not replace**, which is what makes an interrupted walk worth
    /// keeping. Hearting an artist can mean fifty round trips, and writing only
    /// at the end would mean an app closed halfway through kept nothing — so each
    /// record's tracks land as they arrive, and a walk run again adds what is
    /// missing rather than starting over.
    ///
    /// Rows from *other* sources are untouched, and duplicates within one source
    /// are dropped. Two hearted artists sharing a collaboration record each keep
    /// their own row for it, and losing one does not take the other's.
    ///
    /// What this cannot do is notice that something has *left* an artist's
    /// catalog. Nothing needs it to yet: the walk has one version and no reason
    /// to re-run. When ``LibraryIndex/version`` first moves, a rebuild will want
    /// ``removeIndex(from:)`` in front of this, which is why that is separate.
    ///
    /// **Does not stamp `modifiedAt`**, under the rule stated above the library
    /// writes. It used to, which made this the loudest writer in the store on
    /// the one record that most needs to be quiet: hearting a twenty-five-album
    /// artist dirties the kid twenty-six times in a minute, and every one of
    /// those is a child listening to music wearing a parent's edit as a
    /// disguise.
    public func appendIndex(from source: CatalogID, with rows: [LibraryIndexRow], at: Date = .now) {
        guard !rows.isEmpty else { return }
        var known = Set(
            libraryIndex.lazy
                .filter { $0.sourceID == source.rawValue && $0.sourceKind == source.kind.rawValue }
                .compactMap(\.itemID)
        )
        for row in rows where known.insert(row.catalogID).inserted {
            let record = LibraryIndexRecord(row: row, at: at)
            libraryIndex.append(record)
            record.kid = self
        }
    }

    /// Everything one favorite brought in, gone with it.
    public func removeIndex(from source: CatalogID) {
        let doomed = libraryIndex.filter {
            $0.sourceID == source.rawValue && $0.sourceKind == source.kind.rawValue
        }
        delete(doomed)
        libraryIndex.removeAll {
            $0.sourceID == source.rawValue && $0.sourceKind == source.kind.rawValue
        }
    }

    /// Whether a source has been walked by the current version of the walk.
    ///
    /// An empty answer is not "walked and found nothing" — there is no way to
    /// tell those apart from the rows alone, and the cost of being wrong is one
    /// repeated walk rather than a library that is quietly missing an artist.
    public func isIndexed(_ source: CatalogID) -> Bool {
        libraryIndex.contains {
            $0.sourceID == source.rawValue
                && $0.sourceKind == source.kind.rawValue
                && $0.version == LibraryIndex.version
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
    /// **The Recent shelf goes too**, even though it is a projection rather than
    /// history. It is derived from the visits being deleted here, and a parent
    /// who clears the logs and then finds their child's home screen still
    /// listing what they were doing would rightly conclude the delete did not
    /// work. Derived state is not a loophole.
    public func deleteHistory(at: Date = .now) {
        delete(searches)
        delete(plays)
        delete(blocks)
        delete(visits)
        delete(recentTrail)
        delete(summaries)
        searches.removeAll()
        plays.removeAll()
        blocks.removeAll()
        visits.removeAll()
        recentTrail.removeAll()
        summaries.removeAll()
        modifiedAt = at
    }

    /// Deletes the rows, rather than only detaching them.
    ///
    /// **`removeAll()` on a relationship is not a delete.** It nulls the inverse
    /// and leaves the row on disk, orphaned — and because every query here is
    /// `kid?.id == kidID`, an orphan is invisible to the report, so a parent
    /// tapping "clear the logs" would see exactly what they expected while the
    /// rows sat there. The cascade rule does not help: it fires when the *kid*
    /// is deleted, not when a child leaves the array.
    ///
    /// Delete has to mean delete. That is the sentence the whole retention
    /// section rests on, and it was not true.
    private func delete(_ records: [some PersistentModel]) {
        guard let modelContext else { return }
        for record in records { modelContext.delete(record) }
    }

    /// Everything this kid did: their history **and** their library.
    ///
    /// The deliberate ask, offered from the screen that shows a parent what we
    /// hold — because the honest place to offer removing it is the place that
    /// shows it. Distinct from ``deleteHistory(at:)`` precisely so that a
    /// playlist a child made is never taken by a sweep, a retention window, or a
    /// parent who meant "clear the logs".
    ///
    /// Lists, mode and unrated behavior stay. A parent erasing what their child
    /// did is not asking to rebuild their allow list.
    ///
    /// **Suggestions stay too, dismissals included**, and the second half of that
    /// is the part worth arguing with. A suggestion is curation — the parent
    /// built that list, and this screen promises to erase the *child's* data, not
    /// to make an adult redo their work. The dismissal stamped on one is the
    /// child's, so clearing it here has a certain logic to it; what stops that is
    /// that a dismissal withdraws an allow, so wiping the flags would silently
    /// widen what the kid can reach. A delete must never do that. If a parent
    /// wants a passed-on suggestion back, the admin screen offers it in one tap
    /// and says so out loud.
    public func deleteEverything(at: Date = .now) {
        deleteHistory(at: at)
        delete(favorites)
        delete(playlists)
        delete(libraryIndex)
        favorites.removeAll()
        playlists.removeAll()
        libraryIndex.removeAll()
    }
}
