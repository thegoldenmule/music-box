import Foundation
import SwiftData

/// The schema, as a numbered version — there is data in the wild now, and it
/// has to survive every change made to this file from here on.
///
/// **The trap.** A `VersionedSchema.models` list names *live types*, not a
/// shape, so the obvious history —
///
/// ```swift
/// enum FamilySchemaV1: VersionedSchema {
///     static var models: [any PersistentModel.Type] { [Kid.self, /* … */] }
/// }
/// ```
///
/// — silently re-describes itself every time one of those classes changes:
/// add a column to `Kid` and V1 now describes the new shape under the old
/// number, and both ends of a migration stage describe the same thing. Not
/// theoretical — tried here, and it fails loudly: a real old store, opened
/// against a plan whose V1 pointed at the mutated classes, gave
/// `NSCocoaErrorDomain 134504, "Cannot use staged migration with an unknown
/// model version"` and would not open at all. **Freezing a version means
/// duplicating its `@Model` classes** into their own namespace, untouched
/// forever after — sixteen classes and initializers, per frozen version.
///
/// **What is done instead, for now: no migration plan.** Everything since V1
/// is additive — new entities, and columns whose defaults are the truthful
/// value for a row that predates them — so SwiftData infers the migration
/// with nothing frozen. `MigrationTests` proves it against a store an older
/// build actually wrote.
///
/// **When that stops being enough**, the first change a default cannot
/// honestly stand in for needs a custom stage, which needs a real
/// `fromVersion` — freezing the current shape first. The queue, and why each
/// one is not additive:
///
/// - `mode`/`unratedBehavior` to their own record: defaulting them widens a
///   child's sandbox with nothing on screen to say so.
/// - `assertedAt`/`retractedAt` on `PolicyEntryRecord`: every row is live; a
///   backfill that gets the direction wrong retracts a whole allow list.
/// - Ordering ranks replacing the three `position: Int` counters: existing
///   order must map to ranks preserving it, with no undo if it doesn't.
/// - `Kid.sortIndex`/`GrownUp.createdAt` *look* additive and are not — the
///   order a parent typed lives in insertion order, readable now, gone the
///   moment anything syncs, so a stage must capture it, not default it.
/// - `SuggestionRecord.sourcePlaylistID`: existing snapshot rows carry the
///   playlist id *as their own id*, so the column must be backfilled from it.
///
/// Two rules bind every stage when they come. **A migration may never drop a
/// row** — a stage that cannot map something fails loudly and leaves the
/// store alone, rather than writing the half it understood. **A custom stage
/// reads the old shape in `willMigrate` and writes the new one in
/// `didMigrate`**; anything computed between them is lost.
public enum FamilySchemaV2: VersionedSchema {
    /// `2.0.0`: V1 shipped unversioned. No `FamilySchemaV1` — that's the trap above.
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    /// Adding a model without listing it here means it silently does not persist.
    public static var models: [any PersistentModel.Type] {
        [
            Family.self,
            Kid.self,
            GrownUp.self,
            PolicyEntryRecord.self,
            SearchEventRecord.self,
            PlayEventRecord.self,
            BlockEventRecord.self,
            VisitEventRecord.self,
            WeeklySummaryRecord.self,
            // The first projection — see RecentTrailRecord and the retention sweep.
            RecentTrailRecord.self,
            FavoriteRecord.self,
            PlaylistRecord.self,
            PlaylistEntryRecord.self,
            // The parent's shelf — see SuggestionRecord for why it never merges in.
            SuggestionRecord.self,
            SuggestionEntryRecord.self,
            // The second projection; sourced from the library, so it survives `deleteHistory`.
            LibraryIndexRecord.self,

            // MARK: - Added for multiple adults and bound devices

            // `Kid.mode`/`unratedBehavior` stay as a cache — what makes this additive.
            SandboxSettingRecord.self,
            // Where "kid profiles tied to devices" lands; there was nowhere else.
            DeviceRecord.self,
            // A gate that means something on a device that never set one.
            PasscodeEpochRecord.self,
            // A fact with a timestamp, not an absence racing a device back from a drawer.
            HistoryClearRecord.self,
            // Evidence, because guideline 5.1.4 asks for some.
            ConsentRecord.self,
            // The volume leader, batched and keyed so it cannot conflict.
            ActivitySegmentRecord.self,
            // The gap a modifiedAt scan can't cover: a deleted row enumerates nothing.
            PendingDeletionRecord.self,
            SyncMarkRecord.self,
        ]
    }
}

// MARK: - What leaves the device

/// Not `extension FamilyStore` — ambiguous with the module of that name.
public enum SyncCoverage {
    /// Declared, not inferred: "doesn't sync" and "forgot a mapper" look alike.
    public static var syncedModels: [any PersistentModel.Type] {
        [
            Family.self,
            Kid.self,
            GrownUp.self,
            PolicyEntryRecord.self,
            SandboxSettingRecord.self,
            SuggestionRecord.self,
            SuggestionEntryRecord.self,
            FavoriteRecord.self,
            PlaylistRecord.self,
            PlaylistEntryRecord.self,
            DeviceRecord.self,
            PasscodeEpochRecord.self,
            HistoryClearRecord.self,
            ConsentRecord.self,
            ActivitySegmentRecord.self,
            // The one projection that syncs — it survives the retention sweep.
            WeeklySummaryRecord.self,
        ]
    }

    /// Models that stay on the device that wrote them.
    public static var neverSyncs: [any PersistentModel.Type] {
        [
            // Travel as `ActivitySegmentRecord` batches — a deny must not queue behind these.
            VisitEventRecord.self,
            SearchEventRecord.self,
            PlayEventRecord.self,
            BlockEventRecord.self,
            // Recomputed per device — syncing them too duplicates work for nothing.
            RecentTrailRecord.self,
            LibraryIndexRecord.self,
            // This device's own exchange with the server, not the household's.
            PendingDeletionRecord.self,
            SyncMarkRecord.self,
        ]
    }
}
