import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import FamilyStore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// A timing test — batch marking was quadratic, 6.5s on the maintainer's store.
@Suite("Agreeing on a batch stays linear")
@MainActor
struct OutboxScale {
    private static let count = 2_000

    private func storeWithSongs(_ count: Int) throws -> (ModelContext, PlaylistRecord) {
        let context = ModelContext(try FamilyStore.inMemoryContainer())
        let family = Family(at: t0)
        let kid = Kid(name: "Ada", mode: .denyPlusAuto, at: t0)
        context.insert(family)
        context.insert(kid)
        family.addKid(kid, at: t0)

        let playlist = kid.addPlaylist(named: "Everything", at: t0)
        for i in 0..<count {
            _ = playlist.addSong(id: CatalogID(.song, "song-\(i)"), displayName: "S\(i)", at: t0)
        }
        try context.save()
        return (context, playlist)
    }

    @Test("Two thousand records are marked in one pass")
    func markingIsLinear() throws {
        let (context, _) = try storeWithSongs(Self.count)
        let owed = try Outbox.pending(in: context)
        let records = owed.compactMap { change -> SyncedRecord? in
            if case .upsert(let record) = change { record } else { nil }
        }
        #expect(records.count > Self.count)

        let started = Date()
        Outbox.markSynced(records, in: context)
        try context.save()
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 5, "marking \(records.count) records took \(elapsed)s")
        // And it actually agreed, rather than being fast by doing nothing.
        #expect(try Outbox.pending(in: context).isEmpty)
    }

    /// Favorites, not playlist songs — content-addressed names match across stores.
    private func storeWithFavorites(_ count: Int) throws -> ModelContext {
        let context = ModelContext(try FamilyStore.inMemoryContainer())
        let family = Family(id: Self.familyID, at: t0)
        let kid = Kid(id: Self.kidID, name: "Ada", mode: .denyPlusAuto, at: t0)
        context.insert(family)
        context.insert(kid)
        family.addKid(kid, at: t0)

        for i in 0..<count {
            _ = kid.addFavorite(id: CatalogID(.album, "album-\(i)"), displayName: "A\(i)", at: t0)
        }
        try context.save()
        return context
    }

    private static let familyID = UUID(uuidString: "F0000000-0000-0000-0000-00000000000F")!
    private static let kidID = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!

    /// Must match looped single marks — else it's a faster answer to a different one.
    @Test("A batch mark and a loop of single marks agree")
    func batchMatchesSingles() throws {
        let batchContext = try storeWithFavorites(50)
        let loopContext = try storeWithFavorites(50)

        let batched = try Outbox.pending(in: batchContext).compactMap { change -> SyncedRecord? in
            if case .upsert(let record) = change { record } else { nil }
        }
        Outbox.markSynced(batched, in: batchContext)
        try batchContext.save()

        for change in try Outbox.pending(in: loopContext) {
            if case .upsert(let record) = change {
                Outbox.markSynced(record, in: loopContext)
            }
        }
        try loopContext.save()

        let batchMarks = try batchContext.fetch(FetchDescriptor<SyncMarkRecord>())
        let loopMarks = try loopContext.fetch(FetchDescriptor<SyncMarkRecord>())
        #expect(batchMarks.count == loopMarks.count)
        #expect(
            batchMarks.map(\.recordName).sorted() == loopMarks.map(\.recordName).sorted())
        #expect(try Outbox.pending(in: batchContext).isEmpty)
        #expect(try Outbox.pending(in: loopContext).isEmpty)
    }

    /// One name twice must collapse — the single-record path re-reads and can't.
    @Test("A repeated name in one batch stays one mark")
    func duplicatesInABatchCollapse() throws {
        let context = ModelContext(try FamilyStore.inMemoryContainer())
        let family = Family(at: t0)
        context.insert(family)
        try context.save()

        let record = try #require(family.syncRecord())
        Outbox.markSynced([record, record, record], in: context)
        try context.save()

        let marks = try context.fetch(FetchDescriptor<SyncMarkRecord>())
        #expect(marks.filter { $0.recordName == record.name }.count == 1)
    }

    @Test("An empty batch is not a write")
    func emptyBatchDoesNothing() throws {
        let context = ModelContext(try FamilyStore.inMemoryContainer())
        Outbox.markSynced([], in: context)
        #expect(try context.fetch(FetchDescriptor<SyncMarkRecord>()).isEmpty)
    }
}
