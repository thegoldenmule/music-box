import Foundation
import PolicyEngine
import SwiftData

/// Absorbs a record that arrived from another device.
///
/// **This lives in `FamilyStore` and not beside the merge, deliberately.** Every
/// stored property here is `private(set)` and changes only through mutators that
/// stamp `modifiedAt` — the invariant entry-level merge depends on, and one this
/// store enforces structurally rather than by discipline. Putting the inbound
/// half in another module would have meant opening public setters on every
/// field, which dismantles that on the way past. So the module that owns the
/// models owns the only code that writes them.
///
/// ## Three rules
///
/// **Nothing is ever dropped.** A record naming a parent that has not arrived —
/// a policy entry for a kid this device has not seen yet — is *deferred*, not
/// discarded. Out-of-order arrival is normal rather than exceptional: two zones
/// have no arrival ordering between them, so "the household is here, the
/// children are not yet" is a state every joining device passes through. The
/// same rule a migration follows, for the same reason.
///
/// **`modifiedAt` is taken from the record, never from now.** Every mutator here
/// is called with the incoming timestamp. Stamping the local clock instead would
/// make an import look like an edit, and the next export would send it back —
/// two devices ping-ponging a row neither one changed.
///
/// **A field this build cannot read is left alone rather than defaulted.** It is
/// a value from a newer build, and substituting a default is how a newer
/// build's tightening becomes an older build's default. This is the same
/// direction `SandboxSettingRecord` resolution already takes.
public enum SyncApply {
    public enum Outcome: Sendable, Equatable {
        case inserted
        case updated
        /// Nothing was written, and the record must be **kept and retried**.
        case deferred(Reason)
        /// The record is not one this build knows how to place.
        case unknownType(String)
    }

    public enum Reason: Sendable, Equatable {
        /// The kid, family, playlist or suggestion it hangs from is not here yet.
        case missingParent(String)
        /// A field this record cannot be placed without would not read back.
        case unreadable(String)
    }

    /// Resolves the identifiers a record points at. See ``RecordMapper`` on why
    /// every cross-record link is a plain identifier rather than a reference.
    @MainActor
    public struct Context {
        let modelContext: ModelContext

        public init(_ modelContext: ModelContext) {
            self.modelContext = modelContext
        }

        func find<T: PersistentModel>(_ type: T.Type, _ match: (T) -> Bool) -> T? {
            (try? modelContext.fetch(FetchDescriptor<T>()))?.first(where: match)
        }

        func kid(_ id: UUID) -> Kid? { find(Kid.self) { $0.id == id } }
        func family(_ id: UUID) -> Family? { find(Family.self) { $0.id == id } }
        func playlist(_ id: UUID) -> PlaylistRecord? { find(PlaylistRecord.self) { $0.id == id } }
        func suggestion(_ id: UUID) -> SuggestionRecord? {
            find(SuggestionRecord.self) { $0.id == id }
        }

        /// Ancestry travels as five flat columns, the way it is stored.
        func ancestry(_ record: SyncedRecord) -> LibraryAncestry {
            LibraryAncestry(
                albumID: record.string("albumID"),
                albumName: record.string("albumName"),
                artistID: record.string("artistID"),
                artistName: record.string("artistName"),
                artistArtworkURL: nil
            )
        }

        func url(_ record: SyncedRecord, _ field: String) -> URL? {
            if case .url(let value)? = record.fields[field] { return value }
            return nil
        }
    }

    /// Every type this build knows how to place.
    ///
    /// Compared against `RecordMapper.encodableTypes` by a test, so a model that
    /// can be *sent* and cannot be *received* fails the build rather than
    /// becoming a kind of row that silently never arrives — which is the same
    /// failure `SyncCoverage` exists to prevent one layer up, and it is
    /// invisible from the sending device.
    public static let applicableTypes: Set<String> = [
        "Family", "Kid", "GrownUp", "PolicyEntryRecord", "SandboxSettingRecord",
        "SuggestionRecord", "SuggestionEntryRecord", "FavoriteRecord", "PlaylistRecord",
        "PlaylistEntryRecord", "DeviceRecord", "PasscodeEpochRecord", "HistoryClearRecord",
        "ConsentRecord", "ActivitySegmentRecord", "WeeklySummaryRecord",
    ]

    /// Applies one record.
    @MainActor
    public static func apply(_ record: SyncedRecord, in context: Context) -> Outcome {
        switch record.type {
        case Family.syncRecordType: applyFamily(record, in: context)
        case Kid.syncRecordType: applyKid(record, in: context)
        case GrownUp.syncRecordType: applyGrownUp(record, in: context)
        case PolicyEntryRecord.syncRecordType: applyPolicyEntry(record, in: context)
        case SandboxSettingRecord.syncRecordType: applySandboxSetting(record, in: context)
        case SuggestionRecord.syncRecordType: applySuggestion(record, in: context)
        case SuggestionEntryRecord.syncRecordType: applySuggestionEntry(record, in: context)
        case FavoriteRecord.syncRecordType: applyFavorite(record, in: context)
        case PlaylistRecord.syncRecordType: applyPlaylist(record, in: context)
        case PlaylistEntryRecord.syncRecordType: applyPlaylistEntry(record, in: context)
        case DeviceRecord.syncRecordType: applyDevice(record, in: context)
        case PasscodeEpochRecord.syncRecordType: applyPasscodeEpoch(record, in: context)
        case HistoryClearRecord.syncRecordType: applyHistoryClear(record, in: context)
        case ConsentRecord.syncRecordType: applyConsent(record, in: context)
        case ActivitySegmentRecord.syncRecordType: applyActivitySegment(record, in: context)
        case WeeklySummaryRecord.syncRecordType: applyWeeklySummary(record, in: context)
        default: .unknownType(record.type)
        }
    }

    // MARK: - Household

    @MainActor
    private static func applyFamily(_ record: SyncedRecord, in context: Context) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }

        if context.family(id) != nil { return .updated }

        // A household has no mutable fields of its own that travel — its
        // identity *is* its content. Creating it is what matters, because
        // everything else defers until it exists.
        let family = Family(id: id, at: touched)
        context.modelContext.insert(family)
        return .inserted
    }

    @MainActor
    private static func applyKid(_ record: SyncedRecord, in context: Context) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }
        guard let name = record.string(Field.name) else {
            return .deferred(.unreadable(Field.name))
        }

        // The cached columns. Unreadable means a value from a newer build, and
        // the *most restrictive* fallback is the right one for the two fields
        // that decide what a child can reach — the same choice the schema
        // defaults already make.
        let mode = record.string("mode").flatMap(SandboxMode.init(rawValue:)) ?? .allowOnly
        let unrated =
            record.string("unratedBehavior").flatMap(UnratedBehavior.init(rawValue:)) ?? .block

        let kid: Kid
        let outcome: Outcome
        if let existing = context.kid(id) {
            kid = existing
            outcome = .updated
            existing.rename(to: name, at: touched)
            // Through `applyCachedSandbox`, not `setMode`: the latter writes a
            // *decision* row, and importing one would invent a decision nobody
            // made. Decisions arrive as their own records.
            existing.applyCachedSandbox(mode: mode, unratedBehavior: unrated, at: touched)
        } else {
            kid = Kid(id: id, name: name, mode: mode, unratedBehavior: unrated, at: touched)
            context.modelContext.insert(kid)
            outcome = .inserted
        }

        kid.applySync(
            sortIndex: record.int(Field.sortIndex),
            boundAccountRecordName: record.string("boundAccountRecordName"),
            at: touched
        )

        if let familyID = record.uuid(Field.familyID) {
            guard let family = context.family(familyID) else {
                return .deferred(.missingParent(Field.familyID))
            }
            if kid.family?.id != family.id { family.addKid(kid, at: touched) }
        }

        return outcome
    }

    @MainActor
    private static func applyGrownUp(_ record: SyncedRecord, in context: Context) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }
        guard let name = record.string(Field.name) else {
            return .deferred(.unreadable(Field.name))
        }

        let grownUp: GrownUp
        let outcome: Outcome
        if let existing = context.find(GrownUp.self, { $0.id == id }) {
            grownUp = existing
            outcome = .updated
            existing.rename(to: name, at: touched)
        } else {
            grownUp = GrownUp(id: id, name: name, at: touched)
            context.modelContext.insert(grownUp)
            outcome = .inserted
        }

        grownUp.claim(account: record.string("accountRecordName"), at: touched)
        if let index = record.int(Field.sortIndex) { grownUp.setSortIndex(index, at: touched) }

        if let familyID = record.uuid(Field.familyID) {
            guard let family = context.family(familyID) else {
                return .deferred(.missingParent(Field.familyID))
            }
            if grownUp.family?.id != family.id { family.addGrownUp(grownUp, at: touched) }
        }

        return outcome
    }

    // MARK: - Policy

    @MainActor
    private static func applyPolicyEntry(_ record: SyncedRecord, in context: Context) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }
        guard let kidID = record.uuid(Field.kidID) else {
            return .deferred(.unreadable(Field.kidID))
        }
        guard let kid = context.kid(kidID) else { return .deferred(.missingParent(Field.kidID)) }

        guard
            let rawKind = record.string("kind"),
            let rawItemKind = record.string("itemKind"),
            let catalogID = record.string("catalogID"),
            let addedAt = record.date(Field.addedAt)
        else { return .deferred(.unreadable("kind")) }

        // Matched on the natural key rather than on `id`, because that is what
        // the record name is derived from — two devices that both minted a row
        // for the same deny have different ids and the same key, and matching on
        // `id` would insert a second row for a record the server considers one.
        let existing = kid.entries.first {
            $0.kind == rawKind && $0.itemKind == rawItemKind && $0.catalogID == catalogID
        }

        let entry: PolicyEntryRecord
        let outcome: Outcome
        if let existing {
            entry = existing
            outcome = .updated
        } else {
            entry = PolicyEntryRecord(
                id: id,
                rawKind: rawKind,
                rawItemKind: rawItemKind,
                catalogID: catalogID,
                displayName: record.string(Field.displayName) ?? "",
                at: addedAt
            )
            context.modelContext.insert(entry)
            kid.attach(entry, at: touched)
            outcome = .inserted
        }

        // **The standing, taken verbatim.** Both timestamps only move forward,
        // so this is the merge's outcome landing rather than a decision being
        // re-made — and `isLive` reads it exactly as it reads a local edit.
        entry.applySync(
            addedAt: addedAt,
            assertedAt: record.date(Field.assertedAt),
            retractedAt: record.date(Field.retractedAt),
            originatingDeviceID: record.uuid("originatingDeviceID"),
            at: touched
        )

        return outcome
    }

    @MainActor
    private static func applySandboxSetting(_ record: SyncedRecord, in context: Context) -> Outcome
    {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let kidID = record.uuid(Field.kidID) else {
            return .deferred(.unreadable(Field.kidID))
        }
        guard let kid = context.kid(kidID) else { return .deferred(.missingParent(Field.kidID)) }
        guard
            let rawKey = record.string("keyRaw"),
            let key = SandboxSettingKey(rawValue: rawKey),
            let rawValue = record.string("rawValue"),
            let decidedAt = record.date(Field.decidedAt)
        else { return .deferred(.unreadable("keyRaw")) }

        // Append-only: a decision is a fact about a moment and is never edited,
        // so an arriving one either already exists or is new. There is nothing
        // to update, which is the whole reason these rows cannot lose a
        // tightening to a concurrent rename.
        if kid.sandboxSettings.contains(where: { $0.id == id }) { return .updated }

        let decision = SandboxSettingRecord(
            id: id,
            key: key,
            rawValue: rawValue,
            decidedByAccountRecordName: record.string("decidedByAccountRecordName"),
            decidedByGrownUpID: record.uuid("decidedByGrownUpID"),
            originatingDeviceID: record.uuid("originatingDeviceID"),
            at: decidedAt
        )
        context.modelContext.insert(decision)
        kid.attach(decision)
        return .inserted
    }
}

// MARK: - Suggestions

extension SyncApply {
    @MainActor
    fileprivate static func applySuggestion(
        _ record: SyncedRecord, in context: Context
    ) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }
        guard let kidID = record.uuid(Field.kidID) else {
            return .deferred(.unreadable(Field.kidID))
        }
        guard let kid = context.kid(kidID) else { return .deferred(.missingParent(Field.kidID)) }
        guard let rawItemKind = record.string("itemKind"),
            let itemKind = ItemKind(rawValue: rawItemKind)
        else { return .deferred(.unreadable("itemKind")) }

        // The target is the natural key's second half, and a snapshot's reads
        // through to `id` for a row written before `sourcePlaylistID` existed.
        let sourcePlaylistID = record.uuid("sourcePlaylistID")
        let target: SuggestionTarget
        if let catalogID = record.string("catalogID"), !catalogID.isEmpty {
            target = .catalog(CatalogID(itemKind, catalogID))
        } else if itemKind == .playlist {
            target = .snapshotPlaylist(local: sourcePlaylistID ?? id)
        } else {
            // A suggestion with neither is a row this build cannot place.
            // Dropped is not an option; it waits for a build that can.
            return .deferred(.unreadable("catalogID"))
        }

        let displayName = record.string(Field.displayName) ?? ""
        let existing = kid.suggestionRecord(for: target)

        let suggestion: SuggestionRecord
        let outcome: Outcome
        if let existing {
            suggestion = existing
            outcome = .updated
        } else {
            suggestion = SuggestionRecord(
                id: id,
                target: target,
                displayName: displayName,
                position: record.int(Field.position) ?? 0,
                at: record.date(Field.suggestedAt) ?? touched
            )
            context.modelContext.insert(suggestion)
            kid.attach(suggestion, at: touched)
            outcome = .inserted
        }

        suggestion.applySync(
            displayName: displayName,
            subtitle: record.string("subtitle"),
            artworkURL: context.url(record, "artworkURL"),
            note: record.string("note"),
            addedBy: record.string("addedBy"),
            addedByName: record.string("addedByName"),
            position: record.int(Field.position),
            suggestedAt: record.date(Field.suggestedAt),
            dismissedAt: record.date(Field.dismissedAt),
            restoredAt: record.date(Field.restoredAt),
            sourcePlaylistID: sourcePlaylistID,
            at: touched
        )
        return outcome
    }

    @MainActor
    fileprivate static func applySuggestionEntry(
        _ record: SyncedRecord, in context: Context
    ) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }
        guard let suggestionID = record.uuid("suggestionID") else {
            return .deferred(.unreadable("suggestionID"))
        }
        guard let suggestion = context.suggestion(suggestionID) else {
            return .deferred(.missingParent("suggestionID"))
        }
        guard let catalogID = record.string("catalogID") else {
            return .deferred(.unreadable("catalogID"))
        }

        let displayName = record.string(Field.displayName) ?? ""
        let existing = suggestion.entries.first { $0.catalogID == catalogID }

        let entry: SuggestionEntryRecord
        let outcome: Outcome
        if let existing {
            entry = existing
            outcome = .updated
        } else {
            entry = SuggestionEntryRecord(
                id: id,
                catalogID: CatalogID(.song, catalogID),
                displayName: displayName,
                position: record.int(Field.position) ?? 0,
                at: record.date(Field.addedAt) ?? touched
            )
            context.modelContext.insert(entry)
            suggestion.attach(entry)
            outcome = .inserted
        }

        entry.applySync(
            position: record.int(Field.position),
            addedAt: record.date(Field.addedAt),
            displayName: displayName,
            artworkURL: context.url(record, "artworkURL"),
            ancestry: context.ancestry(record),
            at: touched
        )
        return outcome
    }
}

// MARK: - The kid's library

extension SyncApply {
    @MainActor
    fileprivate static func applyFavorite(_ record: SyncedRecord, in context: Context) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }
        guard let kidID = record.uuid(Field.kidID) else {
            return .deferred(.unreadable(Field.kidID))
        }
        guard let kid = context.kid(kidID) else { return .deferred(.missingParent(Field.kidID)) }
        guard let rawItemKind = record.string("itemKind"),
            let catalogID = record.string("catalogID")
        else { return .deferred(.unreadable("catalogID")) }

        let displayName = record.string(Field.displayName) ?? ""
        let existing = kid.favorites.first {
            $0.catalogID == catalogID && $0.itemKind == rawItemKind
        }

        let favorite: FavoriteRecord
        let outcome: Outcome
        if let existing {
            favorite = existing
            outcome = .updated
        } else {
            // The raw initializer, because an `itemKind` this build cannot read
            // must still round-trip rather than being refused — a favorite is
            // not a permission, and `row` already drops what it cannot render.
            favorite = FavoriteRecord(
                id: id,
                rawItemKind: rawItemKind,
                catalogID: catalogID,
                displayName: displayName,
                rawOrigin: record.string("origin") ?? LibraryOrigin.kid.rawValue,
                at: record.date(Field.favoritedAt) ?? touched
            )
            context.modelContext.insert(favorite)
            kid.attach(favorite)
            outcome = .inserted
        }

        favorite.applySync(
            favoritedAt: record.date(Field.favoritedAt),
            displayName: displayName,
            artworkURL: context.url(record, "artworkURL"),
            rawOrigin: record.string("origin"),
            ancestry: context.ancestry(record),
            at: touched
        )
        return outcome
    }

    @MainActor
    fileprivate static func applyPlaylist(_ record: SyncedRecord, in context: Context) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }
        guard let kidID = record.uuid(Field.kidID) else {
            return .deferred(.unreadable(Field.kidID))
        }
        guard let kid = context.kid(kidID) else { return .deferred(.missingParent(Field.kidID)) }

        let name = record.string(Field.name) ?? ""

        let playlist: PlaylistRecord
        let outcome: Outcome
        if let existing = context.playlist(id) {
            playlist = existing
            outcome = .updated
        } else {
            // **The identifier is preserved, and here it is load-bearing.** A
            // playlist's natural key *is* its id, so minting a fresh one would
            // give the same playlist a different record name and put a second
            // copy on the server.
            playlist = PlaylistRecord(id: id, name: name, at: record.date(Field.createdAt) ?? touched)
            context.modelContext.insert(playlist)
            kid.attach(playlist)
            outcome = .inserted
        }

        playlist.applySync(
            name: name,
            createdAt: record.date(Field.createdAt),
            rawOrigin: record.string("origin"),
            appleLibraryID: record.string("appleLibraryID"),
            appleIsOurs: { if case .bool(let v)? = record.fields["appleIsOurs"] { v } else { nil } }(),
            at: touched
        )
        return outcome
    }

    @MainActor
    fileprivate static func applyPlaylistEntry(
        _ record: SyncedRecord, in context: Context
    ) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }
        guard let playlistID = record.uuid("playlistID") else {
            return .deferred(.unreadable("playlistID"))
        }
        guard let playlist = context.playlist(playlistID) else {
            return .deferred(.missingParent("playlistID"))
        }
        guard let catalogID = record.string("catalogID") else {
            return .deferred(.unreadable("catalogID"))
        }

        let displayName = record.string(Field.displayName) ?? ""
        let existing = playlist.entries.first { $0.catalogID == catalogID }

        let entry: PlaylistEntryRecord
        let outcome: Outcome
        if let existing {
            entry = existing
            outcome = .updated
        } else {
            entry = PlaylistEntryRecord(
                id: id,
                catalogID: CatalogID(.song, catalogID),
                displayName: displayName,
                position: record.int(Field.position) ?? 0,
                at: record.date(Field.addedAt) ?? touched
            )
            context.modelContext.insert(entry)
            playlist.attach(entry)
            outcome = .inserted
        }

        entry.applySync(
            position: record.int(Field.position),
            addedAt: record.date(Field.addedAt),
            displayName: displayName,
            artworkURL: context.url(record, "artworkURL"),
            rawOrigin: record.string("origin"),
            ancestry: context.ancestry(record),
            at: touched
        )
        return outcome
    }
}

// MARK: - Devices, gates, consent, activity

extension SyncApply {
    @MainActor
    fileprivate static func applyDevice(_ record: SyncedRecord, in context: Context) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let touched = record.date(Field.modifiedAt) else {
            return .deferred(.unreadable(Field.modifiedAt))
        }

        let label = record.string("label") ?? ""

        let device: DeviceRecord
        let outcome: Outcome
        if let existing = context.find(DeviceRecord.self, { $0.id == id }) {
            device = existing
            outcome = .updated
        } else {
            device = DeviceRecord(
                id: id,
                label: label,
                // The most restrictive role, for the reason the rest of this
                // store fails closed: an unreadable role must not open a player.
                role: record.string("roleRaw").flatMap(DeviceRole.init(rawValue:)) ?? .parentOnly,
                platform: record.string("platformRaw").flatMap(DevicePlatform.init(rawValue:)) ?? .pad,
                at: record.date(Field.enrolledAt) ?? touched
            )
            context.modelContext.insert(device)
            outcome = .inserted
        }

        device.applySync(
            familyID: record.uuid(Field.familyID),
            label: label,
            roleRaw: record.string("roleRaw"),
            platformRaw: record.string("platformRaw"),
            boundKidID: record.uuid("boundKidID"),
            enrolledAccountRecordName: record.string("enrolledAccountRecordName"),
            enrolledByGrownUpID: record.uuid("enrolledByGrownUpID"),
            enrolledAt: record.date(Field.enrolledAt),
            lastSeenAt: record.date(Field.lastSeenAt),
            revokedAt: record.date(Field.revokedAt),
            at: touched
        )
        return outcome
    }

    // The four below are **write-once**: each records something that happened at
    // a moment and is never edited afterwards. So an arriving copy either
    // already exists or is new, and there is nothing to reconcile — which is
    // also why none of them needed a merge rule beyond `immutable`.

    @MainActor
    fileprivate static func applyPasscodeEpoch(
        _ record: SyncedRecord, in context: Context
    ) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        if context.find(PasscodeEpochRecord.self, { $0.id == id }) != nil { return .updated }
        guard let epoch = record.int("epoch"),
            case .data(let salt)? = record.fields["salt"],
            case .data(let verifier)? = record.fields["verifier"],
            let setAt = record.date("setAt")
        else { return .deferred(.unreadable("verifier")) }

        context.modelContext.insert(
            PasscodeEpochRecord(
                id: id,
                familyID: record.uuid(Field.familyID),
                epoch: epoch,
                salt: salt,
                verifier: verifier,
                setByGrownUpID: record.uuid("setByGrownUpID"),
                at: setAt
            )
        )
        return .inserted
    }

    @MainActor
    fileprivate static func applyHistoryClear(
        _ record: SyncedRecord, in context: Context
    ) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        if context.find(HistoryClearRecord.self, { $0.id == id }) != nil { return .updated }
        guard let clearedThrough = record.date("clearedThrough"),
            let issuedAt = record.date("issuedAt")
        else { return .deferred(.unreadable("clearedThrough")) }

        // **Deliberately does not defer on a missing kid.** A clear is an
        // instruction about a range, and it has to be able to land before the
        // child's own record does — otherwise a device that has not finished
        // hydrating would import the history first and the instruction to
        // destroy it second, which is the race the watermark exists to remove.
        context.modelContext.insert(
            HistoryClearRecord(
                id: id,
                kidID: record.uuid(Field.kidID),
                clearedThrough: clearedThrough,
                issuedByGrownUpID: record.uuid("issuedByGrownUpID"),
                at: issuedAt
            )
        )
        return .inserted
    }

    @MainActor
    fileprivate static func applyConsent(_ record: SyncedRecord, in context: Context) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        if context.find(ConsentRecord.self, { $0.id == id }) != nil { return .updated }
        guard let rawScope = record.string("scopeRaw"),
            let scope = ConsentScope(rawValue: rawScope),
            let agreedAt = record.date("agreedAt")
        else { return .deferred(.unreadable("scopeRaw")) }

        var kidIDs: [UUID] = []
        if case .uuids(let ids)? = record.fields["kidIDs"] { kidIDs = ids }

        context.modelContext.insert(
            ConsentRecord(
                id: id,
                familyID: record.uuid(Field.familyID),
                grownUpID: record.uuid("grownUpID"),
                accountRecordName: record.string("accountRecordName"),
                scope: scope,
                kidIDs: kidIDs,
                appVersion: record.string("appVersion") ?? "",
                at: agreedAt
            )
        )
        return .inserted
    }

    @MainActor
    fileprivate static func applyActivitySegment(
        _ record: SyncedRecord, in context: Context
    ) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        if context.find(ActivitySegmentRecord.self, { $0.id == id }) != nil { return .updated }
        guard let dayUTC = record.string("dayUTC"),
            let table = record.string("table"),
            let index = record.int("index"),
            case .data(let payload)? = record.fields["payload"],
            let touched = record.date(Field.modifiedAt)
        else { return .deferred(.unreadable("payload")) }

        context.modelContext.insert(
            ActivitySegmentRecord(
                id: id,
                kidID: record.uuid(Field.kidID),
                deviceID: record.uuid("deviceID"),
                dayUTC: dayUTC,
                table: table,
                index: index,
                payload: payload,
                at: touched
            )
        )
        return .inserted
    }

    @MainActor
    fileprivate static func applyWeeklySummary(
        _ record: SyncedRecord, in context: Context
    ) -> Outcome {
        guard let id = record.uuid(Field.id) else { return .deferred(.unreadable(Field.id)) }
        guard let kidID = record.uuid(Field.kidID) else {
            return .deferred(.unreadable(Field.kidID))
        }
        guard let kid = context.kid(kidID) else { return .deferred(.missingParent(Field.kidID)) }
        guard let weekStart = record.date("weekStart"),
            case .data(let payload)? = record.fields["payload"],
            let touched = record.date(Field.modifiedAt)
        else { return .deferred(.unreadable("payload")) }

        if kid.summaries.contains(where: { $0.id == id }) { return .updated }

        let summary = WeeklySummaryRecord(
            id: id, weekStart: weekStart, payload: payload, at: touched)
        context.modelContext.insert(summary)
        kid.attach(summary)
        return .inserted
    }
}
