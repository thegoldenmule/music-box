import Foundation
import SwiftData

/// The schema, as a numbered version.
///
/// **There is data in the wild, and it has to survive.** That reverses what this
/// package was built on: the store shipped as a bare `Schema([...])` with no
/// version identifier at all, on the reasoning that nothing had shipped so
/// nothing needed migrating.
///
/// ## The trap this file exists to describe
///
/// A `VersionedSchema`'s `models` list names **live types**. It does not capture
/// their shape. So the obvious way to write version history —
///
/// ```swift
/// enum FamilySchemaV1: VersionedSchema {
///     static var models: [any PersistentModel.Type] { [Kid.self, /* … */] }
/// }
/// ```
///
/// — is a declaration that **silently re-describes itself every time one of
/// those classes changes.** Add a column to `Kid` and V1 now describes the new
/// shape under the old version number. Both ends of a migration stage then
/// describe the same thing.
///
/// This is not theoretical; it was tried here and it fails loudly, which is the
/// one mercy. A real store written by the previous build, opened against a plan
/// whose V1 pointed at the mutated classes:
///
/// ```text
/// NSCocoaErrorDomain 134504
/// Cannot use staged migration with an unknown model version.
/// ```
///
/// The store's recorded version matched nothing the plan could describe, so
/// there was no path from it and the store would not open at all.
///
/// **Freezing a version means duplicating its `@Model` classes** into a
/// namespace of their own, with the shape they had, and never touching them
/// again. That is the supported answer and it is expensive: sixteen classes and
/// their initializers, per frozen version.
///
/// ## What is done instead, for now
///
/// **No migration plan.** Everything added since V1 is additive — new entities,
/// and columns whose defaults are the truthful value for a row that predates
/// them — and SwiftData migrates that automatically by inference, with no plan
/// and no frozen copies. `MigrationTests` proves it against a store file an
/// older build actually wrote: the household, both policy entries, the playlist
/// in order, the favorite, the roster and the events all survive.
///
/// ## When that stops being enough
///
/// The first change that a default cannot honestly stand in for needs a custom
/// stage, and a custom stage needs a real `fromVersion` — which means freezing
/// the *current* shape as duplicated classes at that point, before making the
/// change. The queue, and why each one is not additive:
///
/// - `mode` and `unratedBehavior` moving to their own record. Defaulting them
///   widens a child's sandbox with nothing on screen to say so.
/// - `assertedAt`/`retractedAt` on `PolicyEntryRecord`. Every existing row is
///   live; a backfill that gets the direction wrong retracts a family's entire
///   allow list at once.
/// - Ordering ranks replacing the three `position: Int` counters. Existing
///   playlists must map to ranks preserving the order they are in now, and a
///   child's playlist reordering itself during an upgrade has no undo.
/// - `Kid.sortIndex` and `GrownUp.createdAt`. These *look* additive and are not:
///   the order a parent typed is held in the relationship's insertion order, is
///   readable now, and is gone the moment anything syncs. It has to be captured
///   by a stage, not defaulted.
/// - `SuggestionRecord.sourcePlaylistID`. Existing snapshot rows carry the
///   playlist identifier *as their own id*, so the column has to be filled from
///   it before the initializer stops doing that.
///
/// Two rules bind every stage when they come, both learned expensively
/// elsewhere in this store. **A migration may never drop a row** — the lists are
/// the irreplaceable part, and a stage that cannot map something fails loudly
/// and leaves the store alone rather than writing the half it understood.
/// **A custom stage reads the old shape in `willMigrate` and writes the new one
/// in `didMigrate`**; anything computed between them is lost.
public enum FamilySchemaV2: VersionedSchema {
    /// `2.0.0` because V1 is what shipped without a version identifier. There is
    /// deliberately no `FamilySchemaV1` type: it could only be a list of live
    /// classes, which is the trap above rather than a record of anything.
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    /// Every model, in one place. Adding a model without adding it here means it
    /// silently does not persist.
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

            // MARK: - Added for multiple adults and bound devices

            // The two fields that decide what a child can reach, moved off the
            // record a rename also touches. `Kid.mode` and
            // `Kid.unratedBehavior` stay as a cache, which is what makes this
            // additive instead of a custom migration.
            SandboxSettingRecord.self,
            // Where "kid profiles tied to devices" lands. There was nowhere for
            // it to go: the active kid was `family.kids.first` on an unordered
            // relationship and the choice was never persisted at all.
            DeviceRecord.self,
            // A gate that means something on a device that never set one.
            PasscodeEpochRecord.self,
            // Deleting history as a fact with a timestamp rather than an absence
            // that has to win a race against a device coming back from a drawer.
            HistoryClearRecord.self,
            // Evidence, because guideline 5.1.4 asks for some.
            ConsentRecord.self,
            // The volume leader, batched and keyed so it cannot conflict.
            ActivitySegmentRecord.self,
            // The one gap a modifiedAt scan cannot cover: a deleted row leaves
            // nothing to enumerate. See Outbox.
            PendingDeletionRecord.self,
        ]
    }
}

// MARK: - What leaves the device

/// Which models the sync layer carries and which stay put.
///
/// A namespace of its own rather than an extension on ``FamilyStore``, for the
/// reason ``FamilyResolution`` is: inside a module called `FamilyStore`,
/// `extension FamilyStore` is ambiguous with the module and does not compile.
public enum SyncCoverage {
    /// Models the sync layer carries off this device.
    ///
    /// **Declared rather than inferred, because under a hand-rolled mapper
    /// "this model does not sync" and "somebody forgot to write a mapper" are
    /// the same observable state.** A declaration turns the second into a test
    /// failure instead of something a second parent notices months later when
    /// one kind of row never arrives.
    ///
    /// It is also the one place to read what leaves the device, which is what
    /// the privacy copy and the App Review answer both have to be written from.
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
            // A projection, and the one exception to the rule below: it is what
            // *survives* the retention sweep, so a device-local summary means a
            // co-parent permanently loses every swept period with nothing
            // replacing it. Small, cold, and written by a single owner once the
            // sweep has one, so it does not carry the churn the others would.
            WeeklySummaryRecord.self,
        ]
    }

    /// Models that stay on the device that wrote them.
    public static var neverSyncs: [any PersistentModel.Type] {
        [
            // The four event tables. Not because they are private — they are,
            // but they reach a co-parent anyway — but because they travel as
            // `ActivitySegmentRecord` batches instead of as rows. Sending them
            // individually puts a parent's deny behind a backlog of a child's
            // blocked search results, and nothing can reorder a pending queue.
            VisitEventRecord.self,
            SearchEventRecord.self,
            PlayEventRecord.self,
            BlockEventRecord.self,
            // Projections. Each device recomputes these from records that do
            // sync, so syncing them means two devices writing the same derived
            // rows from the same inputs — a conflict generator with nothing to
            // gain. `LibraryIndexRecord`'s recompute is **not free**: it is
            // `LibraryWalk`, which needs MusicKit, network, and that device's
            // own library and storefront, so a co-parent sees an empty Albums
            // column until their phone has walked it.
            RecentTrailRecord.self,
            LibraryIndexRecord.self,
            // Bookkeeping about what this device still owes the server. It
            // describes the outbox, not the household, so it is as device-local
            // as the watermark it is read against.
            PendingDeletionRecord.self,
        ]
    }
}
