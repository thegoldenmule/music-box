import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let band = CatalogID(.artist, "artist-band")
    static let other = CatalogID(.artist, "artist-other")
    static let record = CatalogID(.album, "album-record")
    static let track = CatalogID(.song, "song-track")
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
}

private func visit(
    _ id: CatalogID,
    album: CatalogID? = nil,
    artist: CatalogID? = nil,
    manner: VisitManner = .opened,
    minutes: Double
) -> VisitEvent {
    VisitEvent(
        itemID: id,
        displayName: id.rawValue,
        albumID: album,
        artistID: artist,
        manner: manner,
        at: Fix.t0.addingTimeInterval(minutes * 60)
    )
}

@MainActor
private func storeWithKid() throws -> (ModelContainer, UUID) {
    let container = try FamilyStore.inMemoryContainer()
    let context = ModelContext(container)
    let family = Family(at: Fix.t0)
    let kid = Kid(name: "Robin", mode: .denyPlusAuto, at: Fix.t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.t0)
    try context.save()
    return (container, kid.id)
}

// MARK: -

@Suite("Recording a visit")
struct Recording {
    /// The whole reason this actor is awaited rather than fire-and-forget:
    /// the caller gets the shelf back from the write, so there is no second
    /// read to lose the race against it.
    @Test("The write returns the trail it produced")
    func writeReturnsTheRead() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)

        let trail = try await projector.record(visit(Fix.band, minutes: 1), for: kidID)
        #expect(trail.map(\.catalogID) == [Fix.band])
    }

    @Test("The event and the trail land in the same save")
    func eventAndProjectionAgree() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)
        try await projector.record(visit(Fix.band, minutes: 1), for: kidID)

        try await MainActor.run {
            let context = ModelContext(container)
            let visits = try context.fetch(FetchDescriptor<VisitEventRecord>())
            let rows = try context.fetch(FetchDescriptor<RecentTrailRecord>())
            #expect(visits.count == 1)
            #expect(rows.count == 1)
        }
    }

    /// Opening the record and playing from it is one run, so the shelf is the
    /// record — and the artist loses their tile because their work is on it.
    @Test("An evening on one record leaves one row")
    func aggregationReachesTheStore() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)

        try await projector.record(visit(Fix.band, minutes: 1), for: kidID)
        try await projector.record(visit(Fix.record, artist: Fix.band, minutes: 2), for: kidID)
        let trail = try await projector.record(
            visit(Fix.track, album: Fix.record, artist: Fix.band, manner: .played, minutes: 3),
            for: kidID
        )

        #expect(trail.map(\.catalogID) == [Fix.record])
        try await MainActor.run {
            let context = ModelContext(container)
            // Three visits happened and are all recorded; the shelf is one row.
            let visits = try context.fetch(FetchDescriptor<VisitEventRecord>())
            let rows = try context.fetch(FetchDescriptor<RecentTrailRecord>())
            #expect(visits.count == 3)
            #expect(rows.count == 1)
        }
    }

    @Test("An unknown kid is an error rather than a silent no-op")
    func unknownKid() async throws {
        let (container, _) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)
        let missing = UUID()
        await #expect(throws: RecentsProjector.Failure.unknownKid(missing)) {
            try await projector.record(visit(Fix.band, minutes: 1), for: missing)
        }
    }

    @Test("Another kid's trail is untouched")
    func scopedToOneKid() async throws {
        let (container, kidID) = try await storeWithKid()
        let otherID = try await MainActor.run { () -> UUID in
            let context = ModelContext(container)
            let other = Kid(name: "Sam", mode: .denyPlusAuto, at: Fix.t0)
            context.insert(other)
            try context.save()
            return other.id
        }
        let projector = RecentsProjector(modelContainer: container)
        try await projector.record(visit(Fix.band, minutes: 1), for: kidID)

        let otherTrail = try await projector.trail(for: otherID)
        #expect(otherTrail.isEmpty)
    }
}

// MARK: -

@Suite("Not writing the same arrival twice")
struct Coalescing {
    /// The trail collapses duplicates whatever happens; this is about the log a
    /// parent reads, which should not claim eleven visits to one album.
    @Test("A repeat inside the window writes no second event row")
    func repeatIsCoalesced() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)

        try await projector.record(visit(Fix.record, artist: Fix.band, minutes: 0), for: kidID)
        try await projector.record(
            VisitEvent(
                itemID: Fix.record,
                displayName: "album-record",
                artistID: Fix.band,
                manner: .opened,
                at: Fix.t0.addingTimeInterval(1)
            ),
            for: kidID
        )

        try await MainActor.run {
            let context = ModelContext(container)
            let visits = try context.fetch(FetchDescriptor<VisitEventRecord>())
            #expect(visits.count == 1)
        }
    }

    /// The device clock is the one input this store declares it does not trust:
    /// a kid can move it, and two devices will not agree. A bare
    /// `< coalescingWindow` also swallows every negative interval, so a visit
    /// arriving with an earlier timestamp than the newest on file was discarded
    /// as a duplicate — a genuine visit lost off the shelf and out of the
    /// report. One duplicate row is the cheaper failure.
    @Test("A visit that looks older than the newest one is still a visit")
    func negativeIntervalIsNotARepeat() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)

        try await projector.record(visit(Fix.record, artist: Fix.band, minutes: 0), for: kidID)
        try await projector.record(
            VisitEvent(
                itemID: Fix.record,
                displayName: "album-record",
                artistID: Fix.band,
                manner: .opened,
                // The clock moved backwards between the two arrivals.
                at: Fix.t0.addingTimeInterval(-30)
            ),
            for: kidID
        )

        try await MainActor.run {
            let context = ModelContext(container)
            let visits = try context.fetch(FetchDescriptor<VisitEventRecord>())
            #expect(visits.count == 2)
        }
    }

    @Test("A genuine return later is its own visit")
    func laterReturnIsRecorded() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)

        try await projector.record(visit(Fix.record, artist: Fix.band, minutes: 0), for: kidID)
        try await projector.record(visit(Fix.record, artist: Fix.band, minutes: 5), for: kidID)

        try await MainActor.run {
            let context = ModelContext(container)
            let visits = try context.fetch(FetchDescriptor<VisitEventRecord>())
            let rows = try context.fetch(FetchDescriptor<RecentTrailRecord>())
            #expect(visits.count == 2)
            #expect(rows.count == 1)
        }
    }
}

// MARK: -

@Suite("Rebuilding from the events")
struct Rebuilding {
    /// The property the whole design rests on. If these two could differ, the
    /// incremental path would not be trustworthy and the projection would have
    /// to be recomputed on every read.
    @Test("A rebuilt trail equals the one maintained incrementally")
    func rebuildMatchesIncremental() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)

        let visits = [
            visit(Fix.band, minutes: 1),
            visit(Fix.record, artist: Fix.band, minutes: 2),
            visit(Fix.other, minutes: 3),
            visit(Fix.track, album: Fix.record, artist: Fix.band, manner: .played, minutes: 4),
        ]
        var incremental: [RecentEntry] = []
        for visit in visits {
            incremental = try await projector.record(visit, for: kidID)
        }

        let rebuilt = try await projector.rebuild(for: kidID)
        #expect(rebuilt.map(\.catalogID) == incremental.map(\.catalogID))
    }

    @Test("A trail built by an older walk is replayed on read")
    func versionBumpForcesRebuild() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)
        try await projector.record(visit(Fix.band, minutes: 1), for: kidID)

        // Age the stored row, as a shipped version bump would.
        try await MainActor.run {
            let context = ModelContext(container)
            for row in try context.fetch(FetchDescriptor<RecentTrailRecord>()) {
                row.markVersion(RecentTrail.version - 1)
            }
            try context.save()
        }

        let trail = try await projector.trail(for: kidID)
        #expect(trail.map(\.catalogID) == [Fix.band])
        try await MainActor.run {
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<RecentTrailRecord>())
            #expect(rows.allSatisfy { $0.version == RecentTrail.version })
        }
    }

    /// A kid who has done nothing has nothing to have got wrong, and replaying
    /// the whole event table on every launch for them would be pure waste.
    @Test("An empty trail is never stale")
    func emptyIsNotStale() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)
        let trail = try await projector.trail(for: kidID)
        #expect(trail.isEmpty)
    }
}

// MARK: -

@Suite("Retention and deletion")
struct Lifecycle {
    /// The sweep may delete below this and still leave the shelf rebuildable.
    /// Without it, a version bump months after a sweep empties every kid's home
    /// screen with nothing on screen to explain it.
    @Test("The floor is the oldest visit the trail still depends on")
    func retentionFloor() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)
        try await projector.record(visit(Fix.band, minutes: 1), for: kidID)
        try await projector.record(visit(Fix.other, minutes: 5), for: kidID)

        let floor = try await projector.retentionFloor(for: kidID)
        #expect(floor == Fix.t0.addingTimeInterval(60))
    }

    @Test("An empty trail holds nothing back")
    func emptyFloor() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)
        let floor = try await projector.retentionFloor(for: kidID)
        #expect(floor == nil)
    }

    /// Derived state is not a loophole: a parent who clears the logs must not
    /// find their child's home screen still listing what they were doing.
    @Test("Clearing history empties the shelf as well as the events")
    func deleteHistoryClearsTheTrail() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)
        try await projector.record(visit(Fix.band, minutes: 1), for: kidID)

        try await MainActor.run {
            let context = ModelContext(container)
            let kid = try #require(
                try context.fetch(FetchDescriptor<Kid>(predicate: #Predicate { $0.id == kidID }))
                    .first
            )
            kid.deleteHistory(at: Fix.t0)
            try context.save()
            let rows = try context.fetch(FetchDescriptor<RecentTrailRecord>())
            let visits = try context.fetch(FetchDescriptor<VisitEventRecord>())
            #expect(rows.isEmpty)
            #expect(visits.isEmpty)
        }
    }
}
