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
    /// A shared id let a two-parent merge overwrite one parent's note and attribution.
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

    /// An old row reads through by id, with no backfill write needed.
    @Test("An older row reads its source through its own id")
    func olderRowReadsThrough() throws {
        let (context, kid) = try newKid()

        // Exactly what the old initializer produced: id is the playlist's UUID.
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

    /// Dedup is by target, so an old row and a new suggestion collapse onto one.
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

    /// A suggestion id and a playlist id could previously collide across namespaces.
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
