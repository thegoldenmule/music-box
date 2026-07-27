import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let artist = CatalogID(.artist, "artist-A")
    static let album = CatalogID(.album, "album-A")
    static let song = CatalogID(.song, "song-A")
    static let playlist = CatalogID(.playlist, "playlist-A")
    static let at = Date(timeIntervalSince1970: 1_700_000_000)
}

/// A container with one kid in it, and that kid's identifier.
@MainActor
private func storeWithKid() throws -> (container: ModelContainer, kidID: UUID) {
    let container = try FamilyStore.inMemoryContainer()
    let context = ModelContext(container)
    let family = Family(at: Fix.at)
    let kid = Kid(name: "Robin", mode: .denyPlusAuto, at: Fix.at)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.at)
    try context.save()
    return (container, kid.id)
}

private func play(seconds: Int, origin: PlaybackOrigin = .home) -> PlayEvent {
    PlayEvent(
        songID: Fix.song,
        albumID: Fix.album,
        artistID: Fix.artist,
        displayName: "A Song",
        at: Fix.at,
        secondsPlayed: seconds,
        origin: origin
    )
}

// MARK: - Writing

@Suite("Writing events")
struct Writing {
    @Test("A search is written with every field")
    func search() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(
            SearchEvent(
                term: "dinosaurs",
                at: Fix.at,
                resultCount: 4,
                blockedCount: 2,
                gaveUpEarly: true
            ),
            for: kidID
        )

        // Models are not `Sendable`, so the value types come back out, not rows.
        let stored = try await MainActor.run {
            try ModelContext(container)
                .fetch(FetchDescriptor<SearchEventRecord>())
                .map(\.event)
        }
        #expect(stored.count == 1)
        let event = try #require(stored.first)
        #expect(event.term == "dinosaurs")
        #expect(event.resultCount == 4)
        #expect(event.blockedCount == 2)
        // Zero results with this set would mean "we stopped looking", not
        // "nothing matched". The column has to survive the round trip for that
        // distinction to reach a report at all.
        #expect(event.gaveUpEarly)
    }

    @Test("A block keeps the reason that produced it")
    func block() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(
            BlockEvent(
                itemID: Fix.song,
                displayName: "A Rude Song",
                artistID: Fix.artist,
                at: Fix.at,
                reason: .deniedByParent(Fix.artist),
                origin: .search(term: "dinosaurs")
            ),
            for: kidID
        )

        let stored = try await MainActor.run {
            try ModelContext(container)
                .fetch(FetchDescriptor<BlockEventRecord>())
                .compactMap(\.event)
        }
        let event = try #require(stored.first)
        #expect(event.reason == .deniedByParent(Fix.artist))
        #expect(event.origin == .search(term: "dinosaurs"))
    }

    @Test("A kid's plays are findable by predicate from a context that did not write them")
    func findableByKid() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(play(seconds: 60), for: kidID)

        // This is the query a recents screen runs, and both halves of it have
        // bitten already. Reading `kid.plays` off a long-lived context misses
        // these rows entirely — EventLog is a ModelActor with its own context,
        // which is the point of it — so the read has to be a fetch on a fresh
        // context. And the predicate reaches through an *optional*
        // relationship, which is the part most likely to stop compiling or
        // quietly match nothing.
        let found = try await MainActor.run {
            var descriptor = FetchDescriptor<PlayEventRecord>(
                predicate: #Predicate { $0.kid?.id == kidID },
                sortBy: [SortDescriptor(\.at, order: .reverse)]
            )
            descriptor.fetchLimit = 10
            return try ModelContext(container).fetch(descriptor).map(\.songID)
        }

        #expect(found == [Fix.song.rawValue])
    }

    @Test("One kid's plays do not show up as another's")
    func scopedToKid() async throws {
        let (container, kidID) = try await storeWithKid()
        let strangerID = try await MainActor.run { () -> UUID in
            let context = ModelContext(container)
            let other = Kid(name: "Sam", mode: .denyPlusAuto, at: Fix.at)
            context.insert(other)
            try context.save()
            return other.id
        }

        let log = EventLog(modelContainer: container)
        try await log.record(play(seconds: 60), for: kidID)

        let found = try await MainActor.run {
            try ModelContext(container)
                .fetch(FetchDescriptor<PlayEventRecord>(
                    predicate: #Predicate { $0.kid?.id == strangerID }
                ))
                .count
        }

        #expect(found == 0)
    }

    @Test("Events for an unknown kid fail rather than landing somewhere else")
    func unknownKid() async throws {
        let (container, _) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        let stranger = UUID()

        await #expect(throws: EventLog.Failure.unknownKid(stranger)) {
            try await log.record(play(seconds: 60), for: stranger)
        }
    }

    @Test("Fire-and-forget writes land, and swallow an unknown kid")
    func fireAndForget() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)

        log.log(play(seconds: 60), for: kidID)
        log.log(play(seconds: 60), for: UUID())  // must not crash or throw

        // The write is a detached task; poll rather than assume it has landed.
        var count = 0
        for _ in 0..<50 {
            count = try await MainActor.run {
                try ModelContext(container).fetchCount(FetchDescriptor<PlayEventRecord>())
            }
            if count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(count == 1)
    }
}

// MARK: - The five-second floor

@Suite("A mis-tap is not a listen")
struct MinimumPlay {
    @Test("A play under five seconds is never written", arguments: [0, 1, 4])
    func tooShort(seconds: Int) async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(play(seconds: seconds), for: kidID)

        let count = try await MainActor.run {
            try ModelContext(container).fetchCount(FetchDescriptor<PlayEventRecord>())
        }
        #expect(count == 0)
    }

    @Test("Five seconds is written", arguments: [5, 6, 600])
    func longEnough(seconds: Int) async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(play(seconds: seconds), for: kidID)

        let count = try await MainActor.run {
            try ModelContext(container).fetchCount(FetchDescriptor<PlayEventRecord>())
        }
        #expect(count == 1)
    }
}

// MARK: - Column round trips
//
// These columns are the ones that cannot be added later: a fact nobody wrote
// down at v1 is absent from that period forever. Each case has to survive
// storage, or the column may as well not exist.

@Suite("Origins survive storage", .tags(.roundTrip))
struct Origins {
    static let all: [PlaybackOrigin] = [
        .home,
        .search(term: "dinosaurs"),
        .browse(Fix.artist),
        .browse(Fix.album),
        .playlist(Fix.playlist),
    ]

    @Test("Every origin reads back as itself", arguments: Origins.all)
    func roundTrip(origin: PlaybackOrigin) throws {
        let record = PlayEventRecord(event: play(seconds: 60, origin: origin))
        #expect(record.event?.origin == origin)
    }

    @Test("An origin naming a kind we do not know reads back as nothing")
    func unknownKind() {
        // Not `.home`: a report that silently claims an orphaned row came from
        // the home screen is worse than one that admits it does not know.
        let stored = StoredOrigin(name: "browse", kind: "station", id: "station-A")
        #expect(PlaybackOrigin(stored: stored) == nil)
    }

    @Test("A browse origin without an identifier reads back as nothing")
    func missingID() {
        #expect(PlaybackOrigin(stored: StoredOrigin(name: "browse")) == nil)
    }
}

@Suite("Reasons survive storage", .tags(.roundTrip))
struct Reasons {
    static let all: [BlockReason] = [
        .notOnAllowList,
        .deniedByParent(Fix.artist),
        .deniedByParent(Fix.playlist),
        .explicitContent,
        .unrated,
        .restrictedOutsideApp,
    ]

    @Test("Every reason reads back as itself", arguments: Reasons.all)
    func roundTrip(reason: BlockReason) throws {
        let record = BlockEventRecord(
            event: BlockEvent(
                itemID: Fix.song,
                displayName: "A Song",
                at: Fix.at,
                reason: reason,
                origin: .home
            )
        )
        #expect(record.event?.reason == reason)
    }

    @Test("Every engine reason maps to a stored one", arguments: [
        Reason.notOnAllowList,
        Reason.deniedByParent(Fix.album),
        Reason.explicitContent,
        Reason.unrated,
    ])
    func fromEngine(reason: Reason) {
        // `restrictedOutsideApp` has no engine counterpart on purpose: it comes
        // from Screen Time or Apple Music, and attributing it to a parent's own
        // rule would show them blocking something they never denied.
        #expect(BlockReason(reason) != .restrictedOutsideApp)
    }

    @Test("A deny whose entry cannot be read is not degraded to a bare deny")
    func unreadableDeniedBy() {
        let stored = StoredReason(name: "deniedByParent", deniedByKind: nil, deniedByID: nil)
        #expect(BlockReason(stored: stored) == nil)
    }
}

@Suite("Block items keep their kind", .tags(.roundTrip))
struct BlockedItemKinds {
    @Test("A block on any kind reads back as that kind", arguments: ItemKind.allCases)
    func kindSurvives(kind: ItemKind) throws {
        let id = CatalogID(kind, "id-A")
        let record = BlockEventRecord(
            event: BlockEvent(
                itemID: id,
                displayName: "Something",
                at: Fix.at,
                reason: .notOnAllowList,
                origin: .home
            )
        )
        #expect(record.event?.itemID == id)
    }
}

@Suite("Plays keep their lineage")
struct PlayLineage {
    @Test("Missing lineage reads back as missing, not as a guess")
    func missingLineage() throws {
        let record = PlayEventRecord(
            event: PlayEvent(
                songID: Fix.song,
                displayName: "A Song",
                at: Fix.at,
                secondsPlayed: 60,
                origin: .home
            )
        )
        let event = try #require(record.event)
        // Such a row counts toward totals but cannot be grouped by artist.
        #expect(event.albumID == nil)
        #expect(event.artistID == nil)
        #expect(event.displayName == "A Song")
    }

    @Test("Present lineage reads back with the right kinds")
    func fullLineage() throws {
        let event = try #require(PlayEventRecord(event: play(seconds: 60)).event)
        #expect(event.albumID == Fix.album)
        #expect(event.artistID == Fix.artist)
    }
}

extension Tag {
    @Tag static var roundTrip: Self
}
