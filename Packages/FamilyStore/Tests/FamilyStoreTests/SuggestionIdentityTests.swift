import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let playlist = UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!
}

@MainActor
private func newKid() throws -> (ModelContext, Kid) {
    let context = ModelContext(try FamilyStore.inMemoryContainer())
    let family = Family(at: Fix.t0)
    let kid = Kid(name: "Ada", mode: .denyPlusAuto, unratedBehavior: .block, at: Fix.t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.t0)
    return (context, kid)
}

@Suite("A suggestion's own identity")
@MainActor
struct SuggestionIdentity {
    /// The row used to take the playlist's UUID *as its own id*, on the
    /// reasoning that one identifier beats two that can disagree. That holds for
    /// one writer. For two it means the suggestion's identity is the playlist's,
    /// so a mapper keyed on `id` overwrites one parent's note, their attribution
    /// and every resolved entry under it — and CloudKit rejects the unique
    /// constraint that would have caught it.
    @Test("A snapshot suggestion has an identity of its own")
    func snapshotKeepsItsOwnID() throws {
        let (_, kid) = try newKid()

        let record = kid.addSuggestion(
            target: .snapshotPlaylist(local: Fix.playlist),
            displayName: "Car songs",
            at: Fix.t0
        )

        #expect(record.id != Fix.playlist)
        #expect(record.sourcePlaylistID == Fix.playlist)
        #expect(record.target == .snapshotPlaylist(local: Fix.playlist))
    }

    /// A row written before the column existed *is* keyed by the playlist's
    /// UUID, so `id` is the right answer for it. Reading through means no
    /// backfill write at all — the same shape as `PolicyEntryRecord.assertion`
    /// reading through to `addedAt`.
    @Test("An older row reads its source through its own id")
    func olderRowReadsThrough() throws {
        let (context, kid) = try newKid()

        // Exactly what the old initializer produced: id == the playlist's UUID,
        // no catalogID, and nothing in the new column.
        let legacy = SuggestionRecord(
            id: Fix.playlist,
            rawItemKind: ItemKind.playlist.rawValue,
            catalogID: nil,
            displayName: "Car songs",
            at: Fix.t0
        )
        context.insert(legacy)
        kid.attach(legacy)

        #expect(legacy.sourcePlaylistID == nil)
        #expect(legacy.target == .snapshotPlaylist(local: Fix.playlist))
    }

    /// The dedup is by *target*, so an older row and a new suggestion for the
    /// same playlist still collapse onto one record rather than becoming two
    /// shelves for the same thing.
    @Test("An older row is still found by target")
    func olderRowIsStillDeduped() throws {
        let (context, kid) = try newKid()
        let legacy = SuggestionRecord(
            id: Fix.playlist,
            rawItemKind: ItemKind.playlist.rawValue,
            catalogID: nil,
            displayName: "Car songs",
            at: Fix.t0
        )
        context.insert(legacy)
        kid.attach(legacy)

        let again = kid.addSuggestion(
            target: .snapshotPlaylist(local: Fix.playlist),
            displayName: "Car songs",
            at: Fix.t0
        )

        #expect(again.id == legacy.id)
        #expect(kid.suggestions.count == 1)
    }

    /// A suggestion id and a playlist id could previously be the same value in
    /// two unrelated namespaces.
    @Test("A suggestion id cannot collide with the playlist it points at")
    func noCrossNamespaceCollision() throws {
        let (_, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Car songs", at: Fix.t0)

        let record = kid.addSuggestion(
            target: .snapshotPlaylist(local: playlist.id),
            displayName: "Car songs",
            at: Fix.t0
        )

        #expect(record.id != playlist.id)
        #expect(record.sourcePlaylistID == playlist.id)
    }
}
