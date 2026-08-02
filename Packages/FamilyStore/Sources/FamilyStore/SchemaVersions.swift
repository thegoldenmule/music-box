import Foundation
import SwiftData

/// The schema, as a numbered version, and the plan that carries a store from one
/// version to the next.
///
/// **There is data in the wild, and it has to survive.** That reverses what this
/// package was built on: the store shipped as a bare `Schema([...])` with no
/// version identifier and no migration plan, on the reasoning that nothing had
/// shipped so nothing needed migrating. Every column the sync work adds — and
/// there are around twenty, plus six new record types — lands on stores that
/// already hold a family's curation and a child's playlists.
///
/// The order matters and it is the reason this file exists before any of those
/// columns. A store opened without a plan records no version, so the *first*
/// migration has no `fromVersion` to name and SwiftData has nothing to migrate
/// from. Introducing the version identifier while the model set is still
/// byte-identical to what is on disk is the one moment that costs nothing:
/// the entities and their properties are unchanged, so this is a no-op
/// re-open that leaves a version stamp behind. Adding a column first and
/// versioning afterwards is the same work with a migration already owed.
///
/// **Nothing here is proven against a real store until it has opened one.** The
/// tests write a store with the pre-version shape and re-open it under the plan,
/// which is the closest this machine gets. A store on a device that has been
/// through more history than a test fixture is the maintainer's to check.
public enum FamilySchemaV1: VersionedSchema {
    /// The shape as it stands today, before the sync work adds anything.
    ///
    /// `1.0.0` and not `0.x`: this is what is on disk, whatever it was called
    /// when it was written.
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// Every model, in one place. Adding a model without adding it here means it
    /// silently does not persist.
    ///
    /// **A version's model list is frozen once a store has been written with
    /// it.** When the sync columns land they belong to `FamilySchemaV2`, and
    /// this list stays exactly as it is — editing it in place is the mistake
    /// that makes a migration plan a decoration, because both ends of the stage
    /// then describe the same thing and SwiftData has nothing to do.
    public static var models: [any PersistentModel.Type] {
        [
            Family.self,
            Kid.self,
            // The adults, by the name their kid calls them. Rows point at these
            // by identifier and carry a copy of the name — see GrownUp.
            GrownUp.self,
            PolicyEntryRecord.self,
            SearchEventRecord.self,
            PlayEventRecord.self,
            BlockEventRecord.self,
            VisitEventRecord.self,
            WeeklySummaryRecord.self,
            // The first projection in this store. Derived from VisitEventRecord
            // and rebuildable from it — see RecentTrailRecord for why that
            // matters to the retention sweep.
            RecentTrailRecord.self,
            FavoriteRecord.self,
            PlaylistRecord.self,
            PlaylistEntryRecord.self,
            // The parent's shelf, not the kid's. Beside the library rather than
            // in it — see SuggestionRecord for why a suggestion is never merged
            // into what the kid kept.
            SuggestionRecord.self,
            SuggestionEntryRecord.self,
            // The second projection, and the first whose source is the library
            // rather than the event log — which is what decides that it survives
            // `deleteHistory` and goes with `deleteEverything`.
            LibraryIndexRecord.self,
        ]
    }
}

/// How a store gets from the version it was written with to the one this build
/// speaks.
///
/// Empty of stages today, and that is the point: with one version there is
/// nothing to migrate, and the plan exists so that the *next* change has
/// somewhere to go and a `fromVersion` to name.
///
/// **Two rules for everything added here, both learned the expensive way
/// elsewhere in this store.**
///
/// 1. **A migration may never drop a row.** The lists are the irreplaceable
///    part and a child's playlists are the records with the most of their own
///    work in them. A stage that cannot map something must fail loudly and
///    leave the store alone, not quietly write the half it understood. This is
///    the same asymmetry `PolicyBuilding` already applies to an unreadable row:
///    the cost of stopping is visible, the cost of proceeding is not.
/// 2. **A custom stage reads the old shape in `willMigrate` and writes the new
///    one in `didMigrate`.** Anything computed between them is lost. The one
///    already known to need this is `mode` and `unratedBehavior` moving off
///    `Kid` onto `SandboxSettingRecord` — those are the two fields that decide
///    what a child can reach, so a stage that silently defaults them widens a
///    sandbox without telling anyone. It must carry the stored value across or
///    fail.
public enum FamilyMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [FamilySchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
