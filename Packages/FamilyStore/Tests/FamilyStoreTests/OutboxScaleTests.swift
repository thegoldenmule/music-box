import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import FamilyStore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// Agreeing on a batch, at a size where the difference is the difference.
///
/// **A timing assertion, which this suite otherwise has none of, and the
/// justification is that the bug was only ever visible as time.** Both halves
/// of accepting a batch used to rescan a whole table per record: a mark per
/// upsert, the tombstone table per deletion. Every answer was correct. The cost
/// grew with the square of the store, so it was invisible on a fixture, mild on
/// a real family's first sync, and unusable a year later — measured at 6.5
/// seconds on the maintainer's own store and projected to minutes on one only a
/// few times larger.
///
/// The bound is loose on purpose. It is not a benchmark and machines differ; it
/// is a hundredfold margin over what the linear version does, and nothing but a
/// return to quadratic will cross it.
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

    /// Favorites rather than playlist songs, and fixed identifiers, so that two
    /// separately-built stores produce the *same* record names — a favorite is
    /// content-addressed on `(kid, itemKind, catalogID)` while a playlist mints
    /// a UUID nothing can predict.
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

    /// The batch has to reach the same state as marking one at a time, or it is
    /// a faster answer to a different question.
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

    /// **One name twice in a batch must not become two rows.** The single-record
    /// version cannot hit this — it re-reads before each write — so it is the
    /// one thing the batch version can get wrong that the loop cannot, and a
    /// duplicate mark is a row the outbox would then disagree with itself about.
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
