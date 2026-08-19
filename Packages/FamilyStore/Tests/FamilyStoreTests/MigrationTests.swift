import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

/// The household in `Fixtures/v1-store.sqlite`, so assertions name a value.
private enum V1 {
    static let family = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let kid = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let dad = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
}

/// A writable copy of the fixture — opening a store migrates it in place.
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

/// A store an older build wrote — today's classes only prove V2 opens V2.
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

        // Asserted by value: a quiet default here would widen a sandbox unseen.
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

    /// Every V2 column defaults to the truthful value for a pre-existing row.
    @Test("The new columns arrive holding the truth, not a placeholder")
    func newColumnsAreHonest() throws {
        let fixture = try FixtureStore("v1-store")
        let container = try FamilyStore.container(at: fixture.url)
        let context = ModelContext(container)

        let kid = try #require(try context.fetch(FetchDescriptor<Kid>()).first)
        let grownUp = try #require(try context.fetch(FetchDescriptor<GrownUp>()).first)
        let visit = try #require(try context.fetch(FetchDescriptor<VisitEventRecord>()).first)
        let entry = try #require(kid.entries.first)

        // Neither had happened yet, so neither is claimed.
        #expect(kid.boundAccountRecordName == nil)
        #expect(grownUp.accountRecordName == nil)

        // Nothing recorded which device wrote these, so nothing claims to.
        #expect(visit.originatingDeviceID == nil)
        #expect(entry.originatingDeviceID == nil)

        // Nothing has carried them off the device, which is true.
        #expect(visit.exportedAt == nil)

        // Getting this backwards would retract a family's entire list in one upgrade.
        #expect(entry.retractedAt == nil)
        let allLive = kid.entries.allSatisfy(\.isLive)
        #expect(allLive)
        #expect(kid.liveEntries.count == 2)

        // Uncaptured, not "index zero" — the state the capture exists to fix.
        #expect(kid.sortIndex == nil)
        #expect(grownUp.sortIndex == nil)
    }

    /// Roster order was never stored; it's relationship insertion order, lost on sync.
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

        // Idempotent, so a second device joining later can't reshuffle it.
        #expect(FamilyResolution.captureRosterOrder(of: family) == 0)
    }

    /// A contiguous-position playlist still reads in order under the sparse scheme.
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

    /// A migration that runs twice and changes anything the second time lied.
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

    /// A migrated store can leave itself read-only; asserted separately.
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
        #expect(FamilySchemaV2.models.count == 24)
        #expect(FamilyStore.schema.entities.count == FamilySchemaV2.models.count)
    }

    /// No `FamilySchemaV1`: a `VersionedSchema` of live types re-describes itself.
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

    /// A forgotten mapper looks like "doesn't sync"; this fails the build instead.
    @Test("Every model is declared either synced or never-syncs")
    func coverageIsExhaustive() {
        let all = Set(FamilySchemaV2.models.map { String(describing: $0) })
        #expect(declared == all)
        #expect(all.subtracting(declared).isEmpty, "undeclared: \(all.subtracting(declared))")
    }

    /// `Set` checks can't see a repeat — `SyncMarkRecord` was listed twice and passed.
    @Test("Neither list repeats itself")
    func listsHaveNoDuplicates() {
        for (name, models) in [
            ("syncedModels", SyncCoverage.syncedModels),
            ("neverSyncs", SyncCoverage.neverSyncs),
        ] {
            let names = models.map { String(describing: $0) }
            let repeated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
            #expect(repeated.isEmpty, "\(name) repeats: \(repeated.sorted())")
        }
    }

    @Test("Nothing is in both lists")
    func listsAreDisjoint() {
        let synced = Set(SyncCoverage.syncedModels.map { String(describing: $0) })
        let never = Set(SyncCoverage.neverSyncs.map { String(describing: $0) })
        #expect(synced.intersection(never).isEmpty)
        #expect(synced.count + never.count == declared.count)
    }

    /// Event tables travel as segment batches so a deny can't queue behind them.
    @Test("The event tables are not sent as rows")
    func eventsDoNotSyncDirectly() {
        let never = Set(SyncCoverage.neverSyncs.map { String(describing: $0) })
        for table in ["VisitEventRecord", "SearchEventRecord", "PlayEventRecord", "BlockEventRecord"] {
            #expect(never.contains(table))
        }
    }

    /// `WeeklySummaryRecord` syncs because it outlives the sweep that took its source.
    @Test("Projections stay local, except the one that outlives its source")
    func projectionsStayLocal() {
        let never = Set(SyncCoverage.neverSyncs.map { String(describing: $0) })
        let synced = Set(SyncCoverage.syncedModels.map { String(describing: $0) })
        #expect(never.contains("RecentTrailRecord"))
        #expect(never.contains("LibraryIndexRecord"))
        #expect(synced.contains("WeeklySummaryRecord"))
    }
}
