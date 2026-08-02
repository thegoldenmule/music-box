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
    }

    /// Applies one record.
    @MainActor
    public static func apply(_ record: SyncedRecord, in context: Context) -> Outcome {
        switch record.type {
        case Family.syncRecordType: applyFamily(record, in: context)
        case Kid.syncRecordType: applyKid(record, in: context)
        case GrownUp.syncRecordType: applyGrownUp(record, in: context)
        case PolicyEntryRecord.syncRecordType: applyPolicyEntry(record, in: context)
        case SandboxSettingRecord.syncRecordType: applySandboxSetting(record, in: context)
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
