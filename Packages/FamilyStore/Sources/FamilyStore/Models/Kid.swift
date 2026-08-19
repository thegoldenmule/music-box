import Foundation
import PolicyEngine
import SwiftData

/// Sandbox level lives here, not on ``Family``: siblings can differ.
@Model
public final class Kid {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast
    public private(set) var name: String = ""

    /// Per kid, never a global default — schema defaults are most-restrictive.
    public private(set) var mode: SandboxMode = SandboxMode.allowOnly
    public private(set) var unratedBehavior: UnratedBehavior = UnratedBehavior.block

    /// A column, not a second record — gaining an account is a one-field write.
    public private(set) var boundAccountRecordName: String?

    /// `nil` before capture. See ``FamilyResolution/captureRosterOrder(of:at:)``.
    public private(set) var sortIndex: Int?

    public var family: Family?

    @Relationship(deleteRule: .cascade, inverse: \PolicyEntryRecord.kid)
    public private(set) var entries: [PolicyEntryRecord] = []

    /// Append-only; authority for ``effectiveMode``/``effectiveUnratedBehavior``.
    @Relationship(deleteRule: .cascade, inverse: \SandboxSettingRecord.kid)
    public private(set) var sandboxSettings: [SandboxSettingRecord] = []

    /// Grouped with ``entries``: ``buildPolicy()`` folds a live one in as allow.
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

    /// A projection of ``visits``, not a record — see ``RecentTrailRecord``.
    @Relationship(deleteRule: .cascade, inverse: \RecentTrailRecord.kid)
    public private(set) var recentTrail: [RecentTrailRecord] = []

    // The kid's own library — not events, not touched by ``deleteHistory()``.

    @Relationship(deleteRule: .cascade, inverse: \FavoriteRecord.kid)
    public private(set) var favorites: [FavoriteRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \PlaylistRecord.kid)
    public private(set) var playlists: [PlaylistRecord] = []

    /// Like ``recentTrail``, but survives ``deleteHistory(at:)``.
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

    // `private(set)`, changed only here — every write stamps `modifiedAt`.

    public func rename(to newName: String, at: Date = .now) {
        name = newName
        modifiedAt = at
    }

    /// See ``FamilyResolution/captureRosterOrder(of:at:)``.
    public func setSortIndex(_ index: Int, at: Date = .now) {
        sortIndex = index
        modifiedAt = at
    }

    /// Both halves matter: the row is the authority, the column is the fallback.
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

    /// Internal — tests writing a raw value; ``setMode`` is the public path.
    func attach(_ record: SandboxSettingRecord) {
        sandboxSettings.append(record)
        record.kid = self
    }

    // MARK: - What is actually in force

    /// The only thing that may decide what a child can reach.
    public var effectiveMode: SandboxMode {
        SandboxSettingResolution.resolve(
            sandboxSettings,
            key: .mode,
            parse: SandboxMode.init(rawValue:),
            narrower: SandboxSettingResolution.narrower
        ) ?? mode
    }

    /// What an unrated item is treated as. See ``effectiveMode``.
    public var effectiveUnratedBehavior: UnratedBehavior {
        SandboxSettingResolution.resolve(
            sandboxSettings,
            key: .unratedBehavior,
            parse: UnratedBehavior.init(rawValue:),
            narrower: SandboxSettingResolution.narrower
        ) ?? unratedBehavior
    }

    // MARK: - Lists

    // Callers must `save()` and surface failure, unlike fire-and-forget logging.

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
        // Re-asserts on (kind, itemKind, catalogID): a withdrawn twin sticks.
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

    /// Retracts, never deletes — the retraction is the tombstone a co-parent syncs.
    public func removeEntry(_ record: PolicyEntryRecord, at: Date = .now) {
        record.retract(at: at)
        modifiedAt = at
    }

    /// Every entry that is currently part of the policy.
    public var liveEntries: [PolicyEntryRecord] { entries.filter(\.isLive) }

    // MARK: - Suggestions

    // Awaited like the lists: these grant reach, silence must not imply success.

    /// Upsert: refreshes a live row in place; restores a dismissed one.
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

    /// Matches on attribution, never on name — two grown-ups may share one.
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

    /// Deletes through the context — `removeAll()` alone orphans the row.
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

    /// What the shelf draws. Unreadable rows drop rather than deny.
    public var liveSuggestions: [SuggestionRow] {
        suggestions
            .filter { !$0.isDismissed }
            .sorted(by: SuggestionRecord.newestFirst)
            .compactMap(\.row)
    }

    /// The parent's side of the shelf — the only place a dismissal is visible.
    public var dismissedSuggestions: [SuggestionRow] {
        suggestions
            .filter(\.isDismissed)
            .sorted(by: SuggestionRecord.newestFirst)
            .compactMap(\.row)
    }

    // MARK: - Events

    // Attaching never stamps `modifiedAt` — a play is not a parent's edit.

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

    // Awaited like the lists, but never stamps `modifiedAt`, unlike them.

    /// Upsert refuses a playlist — owned, not favorited — not two rows.
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

    /// Removes every row and its index; tombstones like ``removeEntry(_:at:)``.
    public func removeFavorite(_ catalogID: CatalogID, at: Date = .now) {
        let doomed = favorites.filter {
            $0.catalogID == catalogID.rawValue && $0.itemKind == catalogID.kind.rawValue
        }
        tombstone(doomed, at: at)
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

    /// Append, not replace — a closed-halfway walk keeps its progress.
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

    /// Empty is not "walked and found nothing" — indistinguishable either way.
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

    /// Entries go first — cascade fires on the kid, not the leaving array.
    public func removePlaylist(_ record: PlaylistRecord, at: Date = .now) {
        tombstone(record.entries, at: at)
        tombstone([record], at: at)
        playlists.removeAll { $0.id == record.id }
    }

    public func playlistRecord(for local: UUID) -> PlaylistRecord? {
        playlists.first { $0.id == local }
    }

    // MARK: - History

    /// Records itself — the event tables never sync, so this reaches a co-parent.
    public func deleteHistory(at: Date = .now, issuedBy grownUpID: UUID? = nil) {
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

        // `at`, not `.distantFuture`: a clear must not delete future listening.
        modelContext?.insert(
            HistoryClearRecord(
                kidID: id, clearedThrough: at, issuedByGrownUpID: grownUpID, at: at))

        modifiedAt = at
    }

    /// `removeAll()` on a relationship is not a delete — it orphans the row.
    private func delete(_ records: [some PersistentModel]) {
        guard let modelContext else { return }
        for record in records { modelContext.delete(record) }
    }

    /// Order is the whole of it: `Outbox.delete` needs the row still attached.
    private func tombstone(_ records: [some PersistentModel & SyncEncodable], at: Date) {
        guard let modelContext else { return }
        for record in records { Outbox.delete(record, in: modelContext, at: at) }
    }

    /// Suggestions stay too: wiping a dismissal would silently widen reach.
    public func deleteEverything(at: Date = .now, issuedBy grownUpID: UUID? = nil) {
        deleteHistory(at: at, issuedBy: grownUpID)
        delete(favorites)
        delete(playlists)
        delete(libraryIndex)
        favorites.removeAll()
        playlists.removeAll()
        libraryIndex.removeAll()
    }
}

// MARK: - Absorbing a record another device wrote

// Monotonic: advances a value or leaves it, never clears one on absence.

extension Kid {
    /// Not ``setMode`` — that writes a decision record nobody actually made.
    func applyCachedSandbox(mode: SandboxMode, unratedBehavior: UnratedBehavior, at: Date) {
        self.mode = mode
        self.unratedBehavior = unratedBehavior
        modifiedAt = at
    }

    func applySync(sortIndex: Int?, boundAccountRecordName: String?, at: Date) {
        if let sortIndex { self.sortIndex = sortIndex }
        if let boundAccountRecordName { self.boundAccountRecordName = boundAccountRecordName }
        modifiedAt = at
    }
}
