import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let artist = CatalogID(.artist, "artist-A")
    static let song = CatalogID(.song, "song-A")
}

/// A scratch directory that goes away with the test, so a store file is never
/// shared between two of them.
private struct TempStore: ~Copyable {
    let url: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "FamilyStoreMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "store.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// The store exactly as builds before the migration plan opened it: a bare
/// `Schema` from a model array, no versioned schema, no plan.
///
/// Written out longhand rather than reusing ``FamilySchemaV1/models`` on
/// purpose. The claim under test is that *what is already on disk* opens under
/// the new plan, and a fixture that reads its model list from the new code
/// would pass by construction while proving nothing.
private func legacySchema() -> Schema {
    Schema([
        Family.self,
        Kid.self,
        GrownUp.self,
        PolicyEntryRecord.self,
        SearchEventRecord.self,
        PlayEventRecord.self,
        BlockEventRecord.self,
        VisitEventRecord.self,
        WeeklySummaryRecord.self,
        RecentTrailRecord.self,
        FavoriteRecord.self,
        PlaylistRecord.self,
        PlaylistEntryRecord.self,
        SuggestionRecord.self,
        SuggestionEntryRecord.self,
        LibraryIndexRecord.self,
    ])
}

@MainActor
private func writeLegacyStore(at url: URL) throws -> (family: UUID, kid: UUID) {
    let schema = legacySchema()
    let container = try ModelContainer(
        for: schema,
        configurations: ModelConfiguration(schema: schema, url: url)
    )
    let context = ModelContext(container)

    let family = Family(at: Fix.t0)
    let kid = Kid(name: "Ada", mode: .allowOnly, unratedBehavior: .block, at: Fix.t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.t0)

    // The irreplaceable half: curation, and a child's own work.
    kid.addEntry(kind: .allow, id: Fix.artist, displayName: "A Band", at: Fix.t0)
    let playlist = kid.addPlaylist(named: "Car songs", at: Fix.t0)
    playlist.addSong(id: Fix.song, displayName: "A Song", at: Fix.t0)

    try context.save()
    return (family.id, kid.id)
}

// MARK: -

@Suite("Opening a store an older build wrote")
@MainActor
struct Migration {
    /// The whole reason the version stamp goes in while the model set is still
    /// identical to what is on disk: it is a no-op re-open today, and the first
    /// change after it has a `fromVersion` to name. Adding a column first and
    /// versioning afterwards is the same work with a migration already owed.
    @Test("A store written before the migration plan still opens")
    func legacyStoreOpens() throws {
        let temp = try TempStore()
        let written = try writeLegacyStore(at: temp.url)

        let container = try FamilyStore.container(at: temp.url)
        let context = ModelContext(container)

        let families = try context.fetch(FetchDescriptor<Family>())
        #expect(families.count == 1)
        #expect(families.first?.id == written.family)
    }

    @Test("Nothing is lost on the way through")
    func nothingIsLost() throws {
        let temp = try TempStore()
        let written = try writeLegacyStore(at: temp.url)

        let container = try FamilyStore.container(at: temp.url)
        let context = ModelContext(container)

        let kids = try context.fetch(FetchDescriptor<Kid>())
        let kid = try #require(kids.first)
        #expect(kids.count == 1)
        #expect(kid.id == written.kid)
        #expect(kid.name == "Ada")

        // The two fields that decide what a child can reach. A migration that
        // quietly defaults these widens a sandbox with nothing on screen to say
        // so, which is why they are asserted by value rather than by presence.
        #expect(kid.mode == .allowOnly)
        #expect(kid.unratedBehavior == .block)

        // Curation.
        #expect(kid.entries.count == 1)
        #expect(kid.buildPolicy().policy.entries.count == 1)

        // A child's own work.
        let playlist = try #require(kid.playlists.first)
        #expect(playlist.name == "Car songs")
        #expect(playlist.entries.count == 1)
    }

    /// A migration that runs twice is a migration that ran once and lied about
    /// it. Re-opening must be quiet.
    @Test("Opening it again changes nothing")
    func reopeningIsIdempotent() throws {
        let temp = try TempStore()
        try writeLegacyStore(at: temp.url)

        for _ in 0..<3 {
            let container = try FamilyStore.container(at: temp.url)
            let context = ModelContext(container)
            #expect(try context.fetch(FetchDescriptor<Family>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<Kid>()).count == 1)
            #expect(try context.fetch(FetchDescriptor<PolicyEntryRecord>()).count == 1)
        }
    }

    /// Guards the freeze rule on ``FamilySchemaV1/models``. When the sync
    /// columns land they belong to a V2, and editing V1's list in place would
    /// leave both ends of the stage describing the same thing — a migration plan
    /// that compiles, runs, and does nothing.
    @Test("V1 still describes what is on disk")
    func v1MatchesTheLegacyShape() {
        #expect(FamilySchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(FamilySchemaV1.models.count == legacySchema().entities.count)
        #expect(Schema(versionedSchema: FamilySchemaV1.self).entities.count
            == legacySchema().entities.count)
    }
}
