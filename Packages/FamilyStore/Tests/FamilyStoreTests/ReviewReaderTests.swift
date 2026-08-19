import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let artist = CatalogID(.artist, "artist-A")
    static let other = CatalogID(.artist, "artist-B")
    static let album = CatalogID(.album, "album-A")
    static let song = CatalogID(.song, "song-A")
    static let song2 = CatalogID(.song, "song-B")
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let window = DateInterval(
        start: t0.addingTimeInterval(-3_600),
        end: t0.addingTimeInterval(3_600)
    )
}

@MainActor
private func storeWithKid(
    mode: SandboxMode = .denyPlusAuto,
    entries: [(PolicyEntry.Kind, CatalogID, String)] = []
) throws -> (ModelContainer, UUID) {
    let container = try FamilyStore.inMemoryContainer()
    let context = ModelContext(container)
    let family = Family(at: Fix.t0)
    let kid = Kid(name: "Robin", mode: mode, at: Fix.t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.t0)
    for (kind, id, name) in entries {
        kid.addEntry(kind: kind, id: id, displayName: name, at: Fix.t0)
    }
    try context.save()
    return (container, kid.id)
}

private func block(
    _ id: CatalogID = Fix.song,
    name: String = "A Rude Song",
    artist: CatalogID? = Fix.artist,
    reach: BlockReach = .unseen,
    reason: BlockReason = .explicitContent,
    origin: PlaybackOrigin = .home,
    at: Date = Fix.t0
) -> BlockEvent {
    BlockEvent(
        itemID: id,
        displayName: name,
        artistID: artist,
        rating: .explicit,
        at: at,
        reach: reach,
        reason: reason,
        origin: origin
    )
}

private func play(
    _ id: CatalogID = Fix.song,
    name: String = "A Song",
    seconds: Int = 60,
    origin: PlaybackOrigin = .home,
    at: Date = Fix.t0
) -> PlayEvent {
    PlayEvent(
        songID: id,
        albumID: Fix.album,
        artistID: Fix.artist,
        displayName: name,
        rating: .clean,
        at: at,
        secondsPlayed: seconds,
        origin: origin
    )
}

// MARK: -

@Suite("Reading a window")
struct Windows {
    @Test("Every origin and reason round-trips through the store")
    func everythingRoundTrips() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)

        let origins: [PlaybackOrigin] = [
            .home,
            .search(term: "dinosaurs"),
            .browse(Fix.album),
            .browse(Fix.artist),
            .playlist(CatalogID(.playlist, "pl-1")),
            .kidPlaylist(UUID()),
        ]
        for origin in origins {
            try await log.record(play(origin: origin), for: kidID)
        }

        let reasons: [BlockReason] = [
            .notOnAllowList,
            .deniedByParent(Fix.artist),
            .explicitContent,
            .unrated,
            .restrictedOutsideApp,
        ]
        for reason in reasons {
            try await log.record(block(reason: reason), for: kidID)
        }

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)

        #expect(window.plays.count == origins.count)
        #expect(window.blocks.count == reasons.count)
        #expect(window.unreadable == 0)
        #expect(Set(window.plays.map(\.origin)) == Set(origins))
        #expect(Set(window.blocks.map(\.event.reason)) == Set(reasons))
    }

    @Test("Searches come back with every field")
    func searchesAreRead() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(
            SearchEvent(
                term: "dinosaurs",
                at: Fix.t0,
                resultCount: 4,
                blockedCount: 2,
                gaveUpEarly: true
            ),
            for: kidID
        )

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)

        #expect(window.searches.count == 1)
        #expect(window.searches.first?.term == "dinosaurs")
        #expect(window.searches.first?.resultCount == 4)
        #expect(window.searches.first?.gaveUpEarly == true)
    }

    /// The one stored field distinguishing a filtered result from a played song.
    @Test("A block the kid reached for is distinguishable from one they never saw")
    func reachSurvives() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(block(reach: .unseen, origin: .search(term: "x")), for: kidID)
        try await log.record(block(reach: .reached, origin: .search(term: "x")), for: kidID)

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)

        #expect(window.blocks.filter { $0.event.reach == .reached }.count == 1)
        #expect(window.blocks.filter { $0.event.reach == .unseen }.count == 1)
    }

    @Test("Nothing is filtered out — a blocked row is still a row")
    func nothingIsFiltered() async throws {
        // The rule this component turns on — a denied artist is why it exists.
        let (container, kidID) = try await storeWithKid(
            entries: [(.deny, Fix.artist, "A Band")]
        )
        let log = EventLog(modelContainer: container)
        try await log.record(play(), for: kidID)
        try await log.record(block(reason: .deniedByParent(Fix.artist)), for: kidID)

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)

        #expect(window.plays.count == 1)
        #expect(window.blocks.count == 1)
    }

    @Test("Rows outside the interval are not read")
    func boundedByInterval() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(play(at: Fix.t0), for: kidID)
        try await log.record(play(at: Fix.t0.addingTimeInterval(-86_400)), for: kidID)

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)
        #expect(window.plays.count == 1)
    }

    @Test("Another kid's rows never appear")
    func scopedToOneKid() async throws {
        let (container, kidID) = try await storeWithKid()
        let otherID = try await MainActor.run { () -> UUID in
            let context = ModelContext(container)
            let other = Kid(name: "Sam", mode: .denyPlusAuto, at: Fix.t0)
            context.insert(other)
            try context.save()
            return other.id
        }
        let log = EventLog(modelContainer: container)
        try await log.record(play(), for: kidID)
        try await log.record(play(), for: otherID)

        let reader = ReviewReader(modelContainer: container)
        #expect(try await reader.window(for: kidID, in: Fix.window, at: Fix.t0).plays.count == 1)
    }

    @Test("An unknown kid is an error, not an empty window")
    func unknownKid() async throws {
        let (container, _) = try await storeWithKid()
        let reader = ReviewReader(modelContainer: container)
        let missing = UUID()
        await #expect(throws: ReviewReader.Failure.unknownKid(missing)) {
            try await reader.window(for: missing, in: Fix.window, at: Fix.t0)
        }
    }

    @Test("The window says when it was built")
    func builtAt() async throws {
        let (container, kidID) = try await storeWithKid()
        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)
        #expect(window.builtAt == Fix.t0)
        #expect(window.isEmpty)
    }
}

// MARK: -

@Suite("Rows that will not read back")
struct Unreadable {
    /// The first exercise `nil` on `PlaybackOrigin`/`BlockReason` has ever had.
    @Test("A corrupt origin is counted, not silently dropped")
    func corruptOrigin() async throws {
        let (container, kidID) = try await storeWithKid()
        try await MainActor.run {
            let context = ModelContext(container)
            let kid = try #require(
                try context.fetch(FetchDescriptor<Kid>(predicate: #Predicate { $0.id == kidID }))
                    .first
            )
            let row = PlayEventRecord(songID: Fix.song.rawValue, rawOrigin: "telepathy", at: Fix.t0)
            context.insert(row)
            kid.attach(row)
            try context.save()
        }

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)
        #expect(window.plays.isEmpty)
        #expect(window.unreadable == 1)
    }

    @Test("A corrupt reach is counted too")
    func corruptReach() async throws {
        let (container, kidID) = try await storeWithKid()
        try await MainActor.run {
            let context = ModelContext(container)
            let kid = try #require(
                try context.fetch(FetchDescriptor<Kid>(predicate: #Predicate { $0.id == kidID }))
                    .first
            )
            let row = BlockEventRecord(
                itemID: Fix.song.rawValue,
                rawReach: "glimpsed",
                at: Fix.t0
            )
            context.insert(row)
            kid.attach(row)
            try context.save()
        }

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)
        #expect(window.blocks.isEmpty)
        #expect(window.unreadable == 1)
    }
}

// MARK: -

@Suite("Which rule fired")
struct DeniedBy {
    @Test("A deny names the entry as it stands today")
    func resolvesEntry() async throws {
        let (container, kidID) = try await storeWithKid(
            entries: [(.deny, Fix.artist, "The Loud Band")]
        )
        let log = EventLog(modelContainer: container)
        try await log.record(block(reason: .deniedByParent(Fix.artist)), for: kidID)

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)
        #expect(window.blocks.first?.deniedBy?.displayName == "The Loud Band")
        #expect(window.blocks.first?.deniedBy?.kind == .deny)
    }

    /// After approve-from-report: the block stands, but no rule re-derives.
    @Test("A removed entry leaves the block with its reason and no rule")
    func removedEntry() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(block(reason: .deniedByParent(Fix.artist)), for: kidID)

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)
        #expect(window.blocks.first?.event.reason == .deniedByParent(Fix.artist))
        #expect(window.blocks.first?.deniedBy == nil)
    }

    @Test("An entry of another kind for the same identifier does not answer for it")
    func kindIsPartOfIdentity() async throws {
        // MusicKit identifiers are unique only within a type.
        let (container, kidID) = try await storeWithKid(
            entries: [(.deny, CatalogID(.album, Fix.artist.rawValue), "An Album")]
        )
        let log = EventLog(modelContainer: container)
        try await log.record(block(reason: .deniedByParent(Fix.artist)), for: kidID)

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)
        #expect(window.blocks.first?.deniedBy == nil)
    }
}

// MARK: -

@Suite("What a window covers")
struct CoverageTests {
    @Test("With no summaries, a window is complete")
    func complete() async throws {
        let (container, kidID) = try await storeWithKid()
        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(for: kidID, in: Fix.window, at: Fix.t0)
        #expect(window.coverage == .complete)
    }

    /// A swept week and a quiet week differ; an empty list can only mean one.
    @Test("A summary inside the window says the detail before it is gone")
    func summarised() async throws {
        let (container, kidID) = try await storeWithKid()
        let start = Fix.t0.addingTimeInterval(-30 * 86_400)
        try await MainActor.run {
            let context = ModelContext(container)
            let kid = try #require(
                try context.fetch(FetchDescriptor<Kid>(predicate: #Predicate { $0.id == kidID }))
                    .first
            )
            let summary = WeeklySummaryRecord(weekStart: start, payload: Data())
            context.insert(summary)
            kid.attach(summary)
            try context.save()
        }

        let reader = ReviewReader(modelContainer: container)
        let wide = DateInterval(start: start.addingTimeInterval(-86_400), end: Fix.t0)
        let window = try await reader.window(for: kidID, in: wide, at: Fix.t0)

        guard case .summarisedBefore(let boundary) = window.coverage else {
            Issue.record("expected a summarised window, got \(window.coverage)")
            return
        }
        #expect(boundary == start.addingTimeInterval(7 * 86_400))
    }
}

// MARK: -

@Suite("What came before")
struct PreviouslyHeard {
    @Test("Only songs played before the date count")
    func before() async throws {
        let (container, kidID) = try await storeWithKid()
        let log = EventLog(modelContainer: container)
        try await log.record(play(Fix.song, at: Fix.t0.addingTimeInterval(-86_400)), for: kidID)
        try await log.record(play(Fix.song2, at: Fix.t0), for: kidID)

        let reader = ReviewReader(modelContainer: container)
        let heard = try await reader.previouslyHeard(for: kidID, before: Fix.t0)
        #expect(heard == [Fix.song])
    }
}
