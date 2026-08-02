import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

/// The household in `Fixtures/v1-store.sqlite`, so an assertion names a value
/// rather than whatever happens to come back.
private enum V1 {
    static let family = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let kid = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let dad = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
}

/// A writable copy of a checked-in store file, thrown away with the test.
///
/// Copied rather than opened in place for two reasons: opening a SwiftData store
/// **migrates it**, so a test that used the bundle's copy would rewrite the
/// fixture and every run after the first would be testing V2 against V2; and the
/// bundle directory is not reliably writable anyway.
private final class FixtureStore {
    let url: URL

    init(_ name: String) throws {
        let source = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "sqlite")
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "FamilyStoreMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "\(name).sqlite")
        try FileManager.default.copyItem(at: source, to: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

// MARK: -

/// **The fixture is a store an older build actually wrote**, generated from a
/// git worktree at the commit that introduced versioning and checked in as a
/// binary.
///
/// That is the whole point of it, and the first attempt at these tests got it
/// wrong in a way worth recording. A fixture built by constructing a `Schema`
/// from a model-type array uses the *current* `@Model` classes, so it has the
/// current columns no matter which version identifier it is nominally written
/// under. It passes, it looks like it proves the migration works, and it proves
/// only that V2 opens V2. Verified against this file: `ZKID` genuinely has no
/// `ZBOUNDACCOUNTRECORDNAME` column.
///
/// **When a stage is added, add a fixture with it.** The same trick works every
/// time — worktree at the last commit before the change, write a store, check it
/// in — and each one keeps testing every later migration in the chain. What none
/// of this covers is a store carrying a real family's months of history, which
/// is the maintainer's to try on a device.
@Suite("Opening a store an older build wrote")
@MainActor
struct Migration {
    @Test("A V1 store opens under the V2 schema")
    func v1StoreOpens() throws {
        let fixture = try FixtureStore("v1-store")

        let container = try FamilyStore.container(at: fixture.url)
        let context = ModelContext(container)

        let families = try context.fetch(FetchDescriptor<Family>())
        #expect(families.count == 1)
        #expect(families.first?.id == V1.family)
    }

    /// A migration may never drop a row. This is that rule, as a test.
    @Test("Nothing is lost on the way through")
    func nothingIsLost() throws {
        let fixture = try FixtureStore("v1-store")
        let container = try FamilyStore.container(at: fixture.url)
        let context = ModelContext(container)

        let kid = try #require(try context.fetch(FetchDescriptor<Kid>()).first)
        #expect(kid.id == V1.kid)
        #expect(kid.name == "Ada")

        // The two fields that decide what a child can reach. Asserted by value,
        // not by presence: a migration that quietly defaults these widens a
        // sandbox with nothing on screen to say so.
        //
        // They have since moved onto `SandboxSettingRecord`, and this store has
        // no decision rows because the table did not exist when it was written
        // — so the columns are the answer, and `effectiveMode` has to agree with
        // them. That agreement is exactly what let the move be additive instead
        // of a custom stage over a family's live curation.
        #expect(kid.mode == .allowOnly)
        #expect(kid.unratedBehavior == .block)
        #expect(kid.sandboxSettings.isEmpty)
        #expect(kid.effectiveMode == .allowOnly)
        #expect(kid.effectiveUnratedBehavior == .block)

        // Curation — the irreplaceable half.
        #expect(kid.entries.count == 2)
        let policy = kid.buildPolicy().policy
        #expect(policy.entries.count == 2)
        #expect(policy.entries.contains { $0.kind == .allow && $0.id.rawValue == "artist-A" })
        #expect(policy.entries.contains { $0.kind == .deny && $0.id.rawValue == "album-B" })

        // A child's own work, in the order they put it in.
        let playlist = try #require(kid.playlists.first)
        #expect(playlist.name == "Car songs")
        #expect(playlist.row.entries.map(\.catalogID.rawValue) == ["song-1", "song-2"])
        #expect(kid.favorites.count == 1)

        // The roster, and the events.
        let grownUp = try #require(try context.fetch(FetchDescriptor<GrownUp>()).first)
        #expect(grownUp.id == V1.dad)
        #expect(grownUp.name == "Dad")
        #expect(try context.fetch(FetchDescriptor<VisitEventRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).count == 1)
    }

    /// The line V2 is drawn on: every column it adds has a default that is the
    /// *truthful* value for a row written before it existed. That is what makes
    /// the whole version a lightweight stage with no backfill, and it is worth
    /// asserting rather than assuming — the moment one of these should have been
    /// something else, this version was the wrong place for it.
    @Test("The new columns arrive holding the truth, not a placeholder")
    func newColumnsAreHonest() throws {
        let fixture = try FixtureStore("v1-store")
        let container = try FamilyStore.container(at: fixture.url)
        let context = ModelContext(container)

        let kid = try #require(try context.fetch(FetchDescriptor<Kid>()).first)
        let grownUp = try #require(try context.fetch(FetchDescriptor<GrownUp>()).first)
        let visit = try #require(try context.fetch(FetchDescriptor<VisitEventRecord>()).first)
        let entry = try #require(kid.entries.first)

        // No child had their own Apple Account, and no adult had accepted a
        // share, because neither thing existed.
        #expect(kid.boundAccountRecordName == nil)
        #expect(grownUp.accountRecordName == nil)

        // Nothing recorded which device wrote these, so nothing claims to.
        #expect(visit.originatingDeviceID == nil)
        #expect(entry.originatingDeviceID == nil)

        // Nothing has carried them off the device, which is true.
        #expect(visit.exportedAt == nil)

        // Nothing was ever withdrawn, because nothing could be — so both policy
        // entries are live. Getting this backwards would retract a family's
        // entire allow list in one upgrade, which is why the defaults read
        // through to `addedAt` rather than standing on their own.
        #expect(entry.retractedAt == nil)
        let allLive = kid.entries.allSatisfy(\.isLive)
        #expect(allLive)
        #expect(kid.liveEntries.count == 2)

        // Nobody has captured a roster order yet. That is the state the capture
        // exists to fix, and it must not be mistaken for "index zero".
        #expect(kid.sortIndex == nil)
        #expect(grownUp.sortIndex == nil)
    }

    /// **The capture, against real old data.** The order a parent typed their
    /// children and grown-ups in was never stored — it is the insertion order of
    /// a to-many relationship, readable now and gone the moment anything syncs.
    @Test("The roster order is captured from a store that never recorded one")
    func rosterOrderIsCaptured() throws {
        let fixture = try FixtureStore("v1-store")
        let container = try FamilyStore.container(at: fixture.url)
        let context = ModelContext(container)
        let families = try context.fetch(FetchDescriptor<Family>())
        let family = try #require(families.first)

        let before = family.kids.map(\.id) + family.grownUps.map(\.id)
        let captured = FamilyResolution.captureRosterOrder(of: family)
        try context.save()

        #expect(captured == before.count)
        let kidsCaptured = family.kids.allSatisfy { $0.sortIndex != nil }
        let adultsCaptured = family.grownUps.allSatisfy { $0.sortIndex != nil }
        #expect(kidsCaptured)
        #expect(adultsCaptured)

        // And running it again on the migrated store finds nothing to do, so a
        // second device joining later cannot reshuffle it.
        #expect(FamilyResolution.captureRosterOrder(of: family) == 0)
    }

    /// A playlist written with contiguous positions still reads in its original
    /// order under the sparse scheme, and appending to it does not disturb it.
    @Test("An older playlist keeps its order, and still takes an append")
    func olderPlaylistOrderSurvives() throws {
        let fixture = try FixtureStore("v1-store")
        let container = try FamilyStore.container(at: fixture.url)
        let context = ModelContext(container)

        let kid = try #require(try context.fetch(FetchDescriptor<Kid>()).first)
        let playlist = try #require(kid.playlists.first)
        #expect(playlist.row.entries.map(\.catalogID.rawValue) == ["song-1", "song-2"])

        playlist.addSong(id: CatalogID(.song, "song-3"), displayName: "Three")
        try context.save()

        #expect(playlist.row.entries.map(\.catalogID.rawValue) == ["song-1", "song-2", "song-3"])
    }

    @Test("The five new tables arrive empty and queryable")
    func newTablesExist() throws {
        let fixture = try FixtureStore("v1-store")
        let container = try FamilyStore.container(at: fixture.url)
        let context = ModelContext(container)

        #expect(try context.fetch(FetchDescriptor<DeviceRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PasscodeEpochRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<HistoryClearRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ConsentRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ActivitySegmentRecord>()).isEmpty)
    }

    /// A migration that runs twice is a migration that ran once and lied about
    /// it. The second open finds a V2 store and must do nothing at all.
    @Test("Opening it again changes nothing")
    func reopeningIsIdempotent() throws {
        let fixture = try FixtureStore("v1-store")

        for _ in 0..<3 {
            let container = try FamilyStore.container(at: fixture.url)
            let context = ModelContext(container)
            #expect(try context.fetch(FetchDescriptor<Family>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<Kid>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 2)
            #expect(try context.fetch(FetchDescriptor<PlaylistEntryRecord>()).count == 2)
        }
    }

    /// Writing still works after the store has come through a migration —
    /// separately worth asserting, because a store that opens read-only and
    /// fails on save is a shape SwiftData can leave behind.
    @Test("A migrated store still takes writes")
    func migratedStoreIsWritable() throws {
        let fixture = try FixtureStore("v1-store")
        let container = try FamilyStore.container(at: fixture.url)
        let context = ModelContext(container)

        let kid = try #require(try context.fetch(FetchDescriptor<Kid>()).first)
        kid.addEntry(kind: .deny, id: CatalogID(.artist, "artist-new"), displayName: "New")
        try context.save()

        #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 3)
    }
}

// MARK: - The versions themselves

@Suite("Schema versions")
struct SchemaVersionShape {
    @Test("V2 is the current version and covers every model")
    func versionIsWhatItSays() {
        #expect(FamilySchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(FamilySchemaV2.models.count == 22)
        #expect(FamilyStore.schema.entities.count == FamilySchemaV2.models.count)
    }

    /// There is deliberately no `FamilySchemaV1`, and no migration plan. A
    /// `VersionedSchema` can only name live types, so an "old" version written
    /// that way re-describes itself the moment one of those classes changes —
    /// and a plan built on it made a real store fail to open outright:
    /// `NSCocoaErrorDomain 134504, "Cannot use staged migration with an unknown
    /// model version."` Freezing a version means duplicating its `@Model`
    /// classes, which is the bill the first custom stage has to pay.
    ///
    /// This test has nothing to assert against, so it documents the absence
    /// where someone about to re-add a plan will be reading.
    @Test("No plan is wired up, and the migration suite is what proves that is safe")
    func noPlanIsDeliberate() {
        #expect(FamilyStore.schema.entities.isEmpty == false)
    }
}

// MARK: - What leaves the device

@Suite("Sync coverage")
struct SyncCoverageTests {
    private var declared: Set<String> {
        Set((SyncCoverage.syncedModels + SyncCoverage.neverSyncs).map { String(describing: $0) })
    }

    /// Under a hand-rolled mapper, *"this model does not sync"* and *"somebody
    /// forgot to write a mapper"* are the same observable state. This is what
    /// turns the second into a build failure instead of something a second
    /// parent notices months later when one kind of row never arrives.
    @Test("Every model is declared either synced or never-syncs")
    func coverageIsExhaustive() {
        let all = Set(FamilySchemaV2.models.map { String(describing: $0) })
        #expect(declared == all)
        #expect(all.subtracting(declared).isEmpty, "undeclared: \(all.subtracting(declared))")
    }

    @Test("Nothing is in both lists")
    func listsAreDisjoint() {
        let synced = Set(SyncCoverage.syncedModels.map { String(describing: $0) })
        let never = Set(SyncCoverage.neverSyncs.map { String(describing: $0) })
        #expect(synced.intersection(never).isEmpty)
        #expect(synced.count + never.count == declared.count)
    }

    /// The four event tables travel as `ActivitySegmentRecord` batches, not as
    /// rows — a parent's deny must never queue behind a backlog of a child's
    /// blocked search results, and there is no API to reorder a pending queue.
    @Test("The event tables are not sent as rows")
    func eventsDoNotSyncDirectly() {
        let never = Set(SyncCoverage.neverSyncs.map { String(describing: $0) })
        for table in ["VisitEventRecord", "SearchEventRecord", "PlayEventRecord", "BlockEventRecord"] {
            #expect(never.contains(table))
        }
    }

    /// The exception among the projections, and it is deliberate:
    /// `WeeklySummaryRecord` is what *survives* the retention sweep, so keeping
    /// it device-local means a co-parent permanently loses every swept period
    /// with nothing replacing it.
    @Test("Projections stay local, except the one that outlives its source")
    func projectionsStayLocal() {
        let never = Set(SyncCoverage.neverSyncs.map { String(describing: $0) })
        let synced = Set(SyncCoverage.syncedModels.map { String(describing: $0) })
        #expect(never.contains("RecentTrailRecord"))
        #expect(never.contains("LibraryIndexRecord"))
        #expect(synced.contains("WeeklySummaryRecord"))
    }
}
