import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine
import Testing

@testable import KidLibrary

// MARK: - Fixtures

extension PlayQueue {
    /// A queue over the fixture catalog, all from the same record.
    static func fixture(_ ids: [CatalogID], index: Int = 0, elapsed: TimeInterval = 0) -> PlayQueue {
        PlayQueue(
            entries: ids.map { Entry(item: Fix.item($0), origin: .browse(Fix.record)) },
            index: index,
            elapsed: elapsed
        )
    }
}

private let songs = [Fix.clean, Fix.other, Fix.unrated]

// MARK: - The value

@Suite("The queue as a value")
struct QueueValue {
    @Test("What is loaded is whatever the index points at")
    func current() {
        let queue = PlayQueue.fixture(songs, index: 1)
        #expect(queue.current?.item.id == Fix.other)
        #expect(!queue.isEmpty)
    }

    @Test("An index past the end is an empty queue, not the last song")
    func indexPastTheEnd() {
        let queue = PlayQueue.fixture(songs, index: 9)
        #expect(queue.current == nil)
        #expect(queue.isEmpty)
        // And it does not get guessed back into shape on the way to disk.
        #expect(queue.trimmed().entries.isEmpty)
    }

    @Test("Trimming drops what was already played and rebases the index")
    func trimmingDropsThePast() {
        let trimmed = PlayQueue.fixture(songs, index: 2, elapsed: 30).trimmed()
        #expect(trimmed.entries.map(\.item.id) == [Fix.unrated])
        #expect(trimmed.index == 0)
        #expect(trimmed.current?.item.id == Fix.unrated)
        // Playhead survives the rebase — it belongs to the song, not the position.
        #expect(trimmed.elapsed == 30)
    }

    @Test("Trimming twice changes nothing the second time")
    func trimmingIsIdempotent() {
        let once = PlayQueue.fixture(songs, index: 1).trimmed()
        #expect(once.trimmed() == once)
    }

    @Test("A long queue is capped from the playhead forward")
    func capped() {
        let many = (0..<(PlayQueue.maxEntries * 2)).map { index in
            PlayQueue.Entry(
                item: CatalogItem(id: CatalogID(.song, "song-\(index)"), title: "Song \(index)"),
                origin: .home
            )
        }
        let trimmed = PlayQueue(entries: many, index: 10).trimmed()
        #expect(trimmed.entries.count == PlayQueue.maxEntries)
        // Kept from where the kid is, not the top — never costs the loaded song.
        #expect(trimmed.entries.first?.item.id == CatalogID(.song, "song-10"))
    }
}

// MARK: - Coding

@Suite("Writing a queue down")
struct QueueCoding {
    private func roundTrip(_ queue: PlayQueue) throws -> PlayQueue {
        let data = try JSONEncoder().encode(queue)
        return try JSONDecoder().decode(PlayQueue.self, from: data)
    }

    @Test("A queue survives the round trip whole")
    func wholeQueue() throws {
        let queue = PlayQueue.fixture(songs, index: 1, elapsed: 42)
        #expect(try roundTrip(queue) == queue)
    }

    @Test("Ancestry survives, so a restored song can be judged without the network")
    func ancestrySurvives() throws {
        let restored = try roundTrip(PlayQueue.fixture([Fix.clean]))
        let item = try #require(restored.current?.item)
        #expect(item.ancestors.map(\.id) == [Fix.record, Fix.band])
        #expect(item.ancestors.first?.rating == .clean)
        #expect(item.rating == .clean)
    }

    @Test("Every origin survives, including the one carrying a local identifier")
    func everyOrigin() throws {
        let local = UUID()
        let origins: [PlaybackOrigin] = [
            .home,
            .search(term: "dinosaurs"),
            .browse(Fix.record),
            .playlist(CatalogID(.playlist, "pl.1")),
            .kidPlaylist(local),
        ]
        let queue = PlayQueue(
            entries: origins.map { PlayQueue.Entry(item: Fix.item(Fix.clean), origin: $0) }
        )
        #expect(try roundTrip(queue).entries.map(\.origin) == origins)
    }

    @Test("An origin that does not decode fails the queue rather than becoming home")
    func unreadableOrigin() throws {
        // A case name from a future version, read by today's app.
        let json = """
            {"entries":[{"item":{"id":{"kind":"song","rawValue":"s"},"title":"T","ancestors":[]},\
            "origin":{"name":"radio"}}],"index":0,"elapsed":0}
            """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PlayQueue.self, from: Data(json.utf8))
        }
    }
}

// MARK: - The store

@Suite("Keeping a queue between launches")
struct QueueStorage {
    /// A defaults domain of its own, so tests never see each other's writes.
    private func store(_ name: String = UUID().uuidString) -> UserDefaultsPlayQueueStore {
        UserDefaultsPlayQueueStore(defaults: UserDefaults(suiteName: name)!)
    }

    private let robin = UUID()
    private let sam = UUID()

    @Test("Nothing saved is nothing to come back to")
    func emptyToStartWith() {
        #expect(store().queue(for: robin) == nil)
    }

    @Test("What was playing comes back, trimmed to the playhead")
    func savesAndRestores() {
        let store = store()
        store.save(PlayQueue.fixture(songs, index: 1, elapsed: 12), for: robin)

        let restored = store.queue(for: robin)
        #expect(restored?.entries.map(\.item.id) == [Fix.other, Fix.unrated])
        #expect(restored?.current?.item.id == Fix.other)
        #expect(restored?.elapsed == 12)
    }

    @Test("Two kids keep their own queues")
    func perKid() {
        let store = store()
        store.save(PlayQueue.fixture([Fix.clean]), for: robin)
        store.save(PlayQueue.fixture([Fix.other]), for: sam)

        #expect(store.queue(for: robin)?.current?.item.id == Fix.clean)
        #expect(store.queue(for: sam)?.current?.item.id == Fix.other)
    }

    @Test("Clearing one kid leaves the other alone")
    func clearingIsPerKid() {
        let store = store()
        store.save(PlayQueue.fixture([Fix.clean]), for: robin)
        store.save(PlayQueue.fixture([Fix.other]), for: sam)

        store.clear(for: robin)
        #expect(store.queue(for: robin) == nil)
        #expect(store.queue(for: sam) != nil)
    }

    @Test("Saving an empty queue clears the slot rather than storing an empty one")
    func savingEmptyClears() {
        let store = store()
        store.save(PlayQueue.fixture(songs), for: robin)
        store.save(PlayQueue(entries: []), for: robin)
        #expect(store.queue(for: robin) == nil)
    }

    @Test("A queue whose playhead ran off the end clears the slot too")
    func runOffTheEndClears() {
        let store = store()
        store.save(PlayQueue.fixture(songs), for: robin)
        // What the player holds after skipping past the last song.
        store.save(PlayQueue.fixture(songs, index: songs.count), for: robin)
        #expect(store.queue(for: robin) == nil)
    }

    @Test("Junk under the key reads as nothing to resume")
    func unreadableValue() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(Data("not a queue".utf8), forKey: UserDefaultsPlayQueueStore.key(for: robin))
        #expect(UserDefaultsPlayQueueStore(defaults: defaults).queue(for: robin) == nil)
    }

    @Test("The in-memory store behaves the same way")
    func inMemoryMatches() {
        let store = InMemoryPlayQueueStore()
        store.save(PlayQueue.fixture(songs, index: 1), for: robin)
        #expect(store.queue(for: robin)?.entries.map(\.item.id) == [Fix.other, Fix.unrated])

        store.save(PlayQueue(entries: []), for: robin)
        #expect(store.queue(for: robin) == nil)
    }
}
