import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let song = CatalogID(.song, "song-A")
    static let artist = CatalogID(.artist, "artist-A")

    /// Wednesday 2024-01-10, chosen so the Monday week start is checkable by eye.
    static let now = Date(timeIntervalSince1970: 1_704_844_800)

    static func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }
}

@MainActor
private func store() throws -> (ModelContext, Kid) {
    let context = ModelContext(try FamilyStore.inMemoryContainer())
    let family = Family(at: Fix.daysAgo(400))
    let kid = Kid(name: "Robin", mode: .denyPlusAuto, at: Fix.daysAgo(400))
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.daysAgo(400))
    try context.save()
    return (context, kid)
}

@MainActor
private func addSearch(_ kid: Kid, _ term: String, at: Date, exported: Bool, in c: ModelContext) {
    let row = SearchEventRecord(
        event: SearchEvent(term: term, at: at, resultCount: 2, blockedCount: 0, gaveUpEarly: false))
    c.insert(row)
    kid.attach(row)
    if exported { row.markExported(at: at) }
}

@MainActor
private func addPlay(_ kid: Kid, seconds: Int, at: Date, exported: Bool, in c: ModelContext) {
    let row = PlayEventRecord(
        event: PlayEvent(
            songID: Fix.song, artistID: Fix.artist, displayName: "A Song", rating: .clean,
            at: at, secondsPlayed: seconds, origin: .home))
    c.insert(row)
    kid.attach(row)
    if exported { row.markExported(at: at) }
}

// MARK: -

@Suite("Which week a moment belongs to")
struct Weeks {
    @Test("A week starts on Monday, at midnight UTC")
    func mondayUTC() {
        let start = RetentionWeek.start(of: Fix.now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: start)
        #expect(parts.weekday == 2)  // Monday
        #expect(parts.hour == 0)
        #expect(parts.minute == 0)
    }

    @Test("Every moment in a week maps to the same start")
    func stableWithinAWeek() {
        let start = RetentionWeek.start(of: Fix.now)
        for hours in stride(from: 0, to: 7 * 24, by: 7) {
            let inside = start.addingTimeInterval(Double(hours) * 3_600)
            #expect(RetentionWeek.start(of: inside) == start)
        }
    }

    @Test("A week ends seven days after it starts")
    func endIsSevenDays() {
        let start = RetentionWeek.start(of: Fix.now)
        #expect(RetentionWeek.end(of: start) == start.addingTimeInterval(7 * 86_400))
    }
}

// MARK: -

@Suite("How far back a sweep may reach")
struct Cutoff {
    @Test("The window is ninety days, rounded down to a week")
    func window() {
        let boundary = RetentionCutoff.boundary(now: Fix.now, trailFloor: nil)
        #expect(boundary == RetentionWeek.start(of: Fix.daysAgo(RetentionCutoff.days)))
        #expect(boundary < Fix.daysAgo(RetentionCutoff.days - 1))
    }

    /// Sweeping past the floor leaves a trail a version bump would empty.
    @Test("A trail reaching further back than the window pulls the boundary with it")
    func clampedToTrailFloor() {
        let floor = Fix.daysAgo(200)
        let boundary = RetentionCutoff.boundary(now: Fix.now, trailFloor: floor)
        #expect(boundary <= floor)
    }

    @Test("A trail inside the window does not extend the boundary")
    func recentTrailDoesNotWiden() {
        let withFloor = RetentionCutoff.boundary(now: Fix.now, trailFloor: Fix.daysAgo(3))
        let without = RetentionCutoff.boundary(now: Fix.now, trailFloor: nil)
        #expect(withFloor <= without)
    }

    @Test("Only whole weeks are sweepable")
    func wholeWeeksOnly() {
        let boundary = RetentionWeek.start(of: Fix.daysAgo(90))
        let fullyBefore = RetentionWeek.start(of: Fix.daysAgo(120))
        #expect(RetentionCutoff.isSweepable(weekStart: fullyBefore, boundary: boundary))
        // The week the boundary falls in is not finished below it.
        #expect(!RetentionCutoff.isSweepable(weekStart: boundary, boundary: boundary))
    }
}

// MARK: -

@Suite("Sweeping a kid's old events")
@MainActor
struct Sweeping {
    @Test("Old exported rows are summarised and then deleted")
    func sweeps() throws {
        let (context, kid) = try store()
        addSearch(kid, "dinosaurs", at: Fix.daysAgo(200), exported: true, in: context)
        addPlay(kid, seconds: 120, at: Fix.daysAgo(200), exported: true, in: context)
        try context.save()

        let deleted = RetentionSweep.run(
            for: kid.id, in: context, trailFloor: nil, now: Fix.now)

        #expect(deleted == 2)
        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlayEventRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WeeklySummaryRecord>()).count == 1)
    }

    /// The decision the window rests on: raw terms survive, not counts or top-N.
    @Test("The summary keeps the raw search terms")
    func keepsTerms() throws {
        let (context, kid) = try store()
        addSearch(kid, "why do dogs bark", at: Fix.daysAgo(200), exported: true, in: context)
        try context.save()

        RetentionSweep.run(for: kid.id, in: context, trailFloor: nil, now: Fix.now)

        let payload = try context.fetch(FetchDescriptor<WeeklySummaryRecord>()).first?.payload
        let summary = try JSONDecoder().decode(WeeklySummary.self, from: #require(payload))
        #expect(summary.searches.map(\.term) == ["why do dogs bark"])
        #expect(summary.searchCount == 1)
    }

    /// An unexported row's only copy would be lost for every other device permanently.
    @Test("A row that has never been exported is not swept")
    func unexportedSurvives() throws {
        let (context, kid) = try store()
        addSearch(kid, "not sent yet", at: Fix.daysAgo(200), exported: false, in: context)
        try context.save()

        let deleted = RetentionSweep.run(
            for: kid.id, in: context, trailFloor: nil, now: Fix.now)

        #expect(deleted == 0)
        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).count == 1)
    }

    @Test("Rows inside the window are left alone")
    func recentSurvives() throws {
        let (context, kid) = try store()
        addSearch(kid, "last week", at: Fix.daysAgo(7), exported: true, in: context)
        try context.save()

        let deleted = RetentionSweep.run(
            for: kid.id, in: context, trailFloor: nil, now: Fix.now)

        #expect(deleted == 0)
        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).count == 1)
    }

    @Test("A trail reaching back past the window protects the rows under it")
    func trailFloorProtects() throws {
        let (context, kid) = try store()
        addSearch(kid, "old but on the shelf", at: Fix.daysAgo(200), exported: true, in: context)
        try context.save()

        let deleted = RetentionSweep.run(
            for: kid.id, in: context, trailFloor: Fix.daysAgo(300), now: Fix.now)

        #expect(deleted == 0)
        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).count == 1)
    }

    /// Runs every sync pass, so a second pass must re-stamp nothing and cost zero.
    @Test("Sweeping twice deletes nothing more and does not re-stamp the summary")
    func idempotent() throws {
        let (context, kid) = try store()
        addSearch(kid, "dinosaurs", at: Fix.daysAgo(200), exported: true, in: context)
        try context.save()

        RetentionSweep.run(for: kid.id, in: context, trailFloor: nil, now: Fix.now)
        let stamp = try context.fetch(FetchDescriptor<WeeklySummaryRecord>()).first?.modifiedAt

        let again = RetentionSweep.run(for: kid.id, in: context, trailFloor: nil, now: Fix.now)

        #expect(again == 0)
        #expect(try context.fetch(FetchDescriptor<WeeklySummaryRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<WeeklySummaryRecord>()).first?.modifiedAt == stamp)
    }

    /// Replaces owner/lease: two devices on one week must write identical bytes.
    @Test("The same events give byte-identical payloads")
    func deterministic() throws {
        func payload() throws -> Data {
            let (context, kid) = try store()
            for i in 0..<5 {
                addSearch(
                    kid, "term \(i)", at: Fix.daysAgo(200 - i), exported: true, in: context)
                addPlay(
                    kid, seconds: 30 + i, at: Fix.daysAgo(200 - i), exported: true, in: context)
            }
            try context.save()
            RetentionSweep.run(for: kid.id, in: context, trailFloor: nil, now: Fix.now)
            let rows = try context.fetch(FetchDescriptor<WeeklySummaryRecord>())
            return rows.sorted { $0.weekStart < $1.weekStart }.map(\.payload).reduce(Data(), +)
        }

        let first = try payload()
        let second = try payload()
        #expect(first == second)
    }

    /// Exempt from the sweep, not `deleteHistory` — the floor keeps it rebuildable
    @Test("The Recent shelf and a kid's own work are never swept")
    func exemptions() throws {
        let (context, kid) = try store()
        addSearch(kid, "dinosaurs", at: Fix.daysAgo(200), exported: true, in: context)

        let trail = RecentTrailRecord(
            entry: RecentEntry(
                catalogID: Fix.song, displayName: "A Song", artworkURL: nil, albumID: nil,
                artistID: nil, at: Fix.daysAgo(200)))
        context.insert(trail)
        kid.attach(trail)

        let favorite = FavoriteRecord(
            catalogID: Fix.song, displayName: "A Song", at: Fix.daysAgo(200))
        context.insert(favorite)
        kid.attach(favorite)
        try context.save()

        RetentionSweep.run(for: kid.id, in: context, trailFloor: nil, now: Fix.now)

        #expect(try context.fetch(FetchDescriptor<RecentTrailRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<FavoriteRecord>()).count == 1)
    }

    @Test("Another kid's rows are untouched")
    func perKid() throws {
        let (context, kid) = try store()
        let other = Kid(name: "Sam", mode: .denyPlusAuto, at: Fix.daysAgo(400))
        context.insert(other)
        addSearch(kid, "robin's", at: Fix.daysAgo(200), exported: true, in: context)
        addSearch(other, "sam's", at: Fix.daysAgo(200), exported: true, in: context)
        try context.save()

        RetentionSweep.run(for: kid.id, in: context, trailFloor: nil, now: Fix.now)

        let left = try context.fetch(FetchDescriptor<SearchEventRecord>())
        #expect(left.count == 1)
        #expect(left.first?.event.term == "sam's")
    }

    /// An empty list must not claim "nothing happened" about a swept week.
    @Test("A reader can tell a swept week from an empty one")
    func coverageIsReported() async throws {
        let container = try FamilyStore.inMemoryContainer()
        let context = ModelContext(container)
        let family = Family(at: Fix.daysAgo(400))
        let kid = Kid(name: "Robin", mode: .denyPlusAuto, at: Fix.daysAgo(400))
        context.insert(family)
        context.insert(kid)
        family.addKid(kid, at: Fix.daysAgo(400))
        addSearch(kid, "dinosaurs", at: Fix.daysAgo(200), exported: true, in: context)
        try context.save()

        RetentionSweep.run(for: kid.id, in: context, trailFloor: nil, now: Fix.now)

        let reader = ReviewReader(modelContainer: container)
        let window = try await reader.window(
            for: kid.id,
            in: DateInterval(start: Fix.daysAgo(300), end: Fix.now),
            at: Fix.now
        )
        #expect(window.coverage != .complete)
    }
}
