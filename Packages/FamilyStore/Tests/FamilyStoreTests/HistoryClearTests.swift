import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum When {
    static let monday = Date(timeIntervalSince1970: 1_700_000_000)
    static let tuesday = monday.addingTimeInterval(86_400)
    static let wednesday = monday.addingTimeInterval(2 * 86_400)
    static let thursday = monday.addingTimeInterval(3 * 86_400)
}

@MainActor
private func store(kids names: [String] = ["Robin"]) throws -> (ModelContext, Family, [Kid]) {
    let context = ModelContext(try FamilyStore.inMemoryContainer())
    let family = Family(at: When.monday)
    context.insert(family)
    var kids: [Kid] = []
    for name in names {
        let kid = Kid(name: name, mode: .denyPlusAuto, at: When.monday)
        context.insert(kid)
        family.addKid(kid, at: When.monday)
        kids.append(kid)
    }
    return (context, family, kids)
}

/// Through `attach`, like `EventLog`: bypasses the `private(set)` relationship.
@MainActor
private func search(_ kid: Kid, _ term: String, at: Date, in context: ModelContext) {
    let row = SearchEventRecord(
        event: SearchEvent(
            term: term, at: at, resultCount: 1, blockedCount: 0, gaveUpEarly: false))
    context.insert(row)
    kid.attach(row)
}

// MARK: -

@Suite("What a set of clear instructions adds up to")
struct TheArithmetic {
    private func record(_ kidID: UUID, through: Date, issued: Date) -> HistoryClearRecord {
        HistoryClearRecord(kidID: kidID, clearedThrough: through, at: issued)
    }

    @Test("No instructions is nothing to do")
    func nothing() {
        #expect(HistoryClears.boundary(for: UUID(), in: []) == nil)
    }

    @Test("One instruction is its own boundary")
    func single() {
        let kid = UUID()
        let rows = [record(kid, through: When.tuesday, issued: When.tuesday)]
        #expect(HistoryClears.boundary(for: kid, in: rows) == When.tuesday)
    }

    @Test("Another child's instruction is not this child's")
    func perKid() {
        let robin = UUID()
        let sam = UUID()
        let rows = [record(sam, through: When.tuesday, issued: When.tuesday)]
        #expect(HistoryClears.boundary(for: robin, in: rows) == nil)
    }

    /// Picking by `issuedAt` would let clock skew undo a deliberate deletion.
    @Test("The instruction that reaches furthest wins, not the newest one")
    func furthestWins() {
        let kid = UUID()
        let rows = [
            record(kid, through: When.wednesday, issued: When.monday),
            record(kid, through: When.tuesday, issued: When.thursday),
        ]
        #expect(HistoryClears.boundary(for: kid, in: rows) == When.wednesday)
    }

    @Test("A device that has done the work has nothing outstanding")
    func upToDate() {
        let kid = UUID()
        let rows = [record(kid, through: When.tuesday, issued: When.tuesday)]
        #expect(
            HistoryClears.outstanding(for: kid, in: rows, watermark: When.tuesday) == nil)
    }

    @Test("A device behind the boundary has the boundary outstanding")
    func behind() {
        let kid = UUID()
        let rows = [record(kid, through: When.wednesday, issued: When.wednesday)]
        #expect(
            HistoryClears.outstanding(for: kid, in: rows, watermark: When.monday)
                == When.wednesday)
    }

    /// No watermark fails toward redoing work — a clear twice deletes nothing extra.
    @Test("A device with no watermark has everything outstanding")
    func noWatermark() {
        let kid = UUID()
        let rows = [record(kid, through: When.tuesday, issued: When.tuesday)]
        #expect(
            HistoryClears.outstanding(for: kid, in: rows, watermark: nil) == When.tuesday)
    }
}

// MARK: -

@Suite("Clearing locally writes down that it happened")
@MainActor
struct LocalClearRecords {
    @Test("A clear leaves an instruction behind")
    func writesTheRow() throws {
        let (context, _, kids) = try store()
        let robin = kids[0]
        search(robin, "dinosaurs", at: When.monday, in: context)

        robin.deleteHistory(at: When.tuesday)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<HistoryClearRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.kidID == robin.id)
        #expect(rows.first?.clearedThrough == When.tuesday)
    }

    /// A clear is about the past; reaching forward would keep deleting unnoticed.
    @Test("The instruction does not reach past the moment it was issued")
    func doesNotReachForward() throws {
        let (context, _, kids) = try store()
        let robin = kids[0]

        robin.deleteHistory(at: When.tuesday)
        search(robin, "after the clear", at: When.wednesday, in: context)
        try context.save()

        HistoryClearApplier.apply(
            for: [robin.id], in: context, watermarks: InMemoryHistoryClearWatermark())

        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).count == 1)
    }

    @Test("Who asked is recorded when it is known")
    func recordsWhoAsked() throws {
        let (context, _, kids) = try store()
        let dad = UUID()

        kids[0].deleteHistory(at: When.tuesday, issuedBy: dad)
        try context.save()

        let row = try context.fetch(FetchDescriptor<HistoryClearRecord>()).first
        #expect(row?.issuedByGrownUpID == dad)
    }
}

// MARK: -

/// Simulates a second device: event tables never sync, only the instruction does.
@Suite("A device carrying out somebody else's clear")
@MainActor
struct ApplyingAnArrival
{
    @Test("Rows at or before the boundary go")
    func deletesUpToTheBoundary() throws {
        let (context, _, kids) = try store()
        let robin = kids[0]
        search(robin, "before", at: When.monday, in: context)
        search(robin, "on the boundary", at: When.tuesday, in: context)
        search(robin, "after", at: When.wednesday, in: context)
        context.insert(
            HistoryClearRecord(kidID: robin.id, clearedThrough: When.tuesday, at: When.tuesday))
        try context.save()

        let touched = HistoryClearApplier.apply(
            for: [robin.id], in: context, watermarks: InMemoryHistoryClearWatermark())

        let left = try context.fetch(FetchDescriptor<SearchEventRecord>())
        #expect(touched == [robin.id])
        #expect(left.count == 1)
        #expect(left.first?.term == "after")
    }

    /// A late-arriving clear must not also take a week of listening nobody asked for.
    @Test("A late arrival leaves everything written since alone")
    func lateArrivalIsBounded() throws {
        let (context, _, kids) = try store()
        let robin = kids[0]
        for day in [When.wednesday, When.thursday] {
            search(robin, "day \(day.timeIntervalSince1970)", at: day, in: context)
        }
        context.insert(
            HistoryClearRecord(kidID: robin.id, clearedThrough: When.tuesday, at: When.tuesday))
        try context.save()

        HistoryClearApplier.apply(
            for: [robin.id], in: context, watermarks: InMemoryHistoryClearWatermark())

        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).count == 2)
    }

    @Test("One child's clear does not touch another child's history")
    func siblingsAreSeparate() throws {
        let (context, _, kids) = try store(kids: ["Robin", "Sam"])
        search(kids[0], "robin's", at: When.monday, in: context)
        search(kids[1], "sam's", at: When.monday, in: context)
        context.insert(
            HistoryClearRecord(
                kidID: kids[0].id, clearedThrough: When.tuesday, at: When.tuesday))
        try context.save()

        HistoryClearApplier.apply(
            for: kids.map(\.id), in: context, watermarks: InMemoryHistoryClearWatermark())

        let left = try context.fetch(FetchDescriptor<SearchEventRecord>())
        #expect(left.count == 1)
        #expect(left.first?.term == "sam's")
    }

    /// Derived state isn't a loophole: a cleared log must also clear the Recent shelf.
    @Test("The Recent shelf goes with the visits it was built from")
    func shelfGoesToo() throws {
        let (context, _, kids) = try store()
        let robin = kids[0]
        let trail = RecentTrailRecord(
            entry: RecentEntry(
                catalogID: CatalogID(.song, "song-A"),
                displayName: "A Song",
                artworkURL: nil,
                albumID: nil,
                artistID: nil,
                at: When.monday
            )
        )
        context.insert(trail)
        robin.attach(trail)
        context.insert(
            HistoryClearRecord(kidID: robin.id, clearedThrough: When.tuesday, at: When.tuesday))
        try context.save()

        HistoryClearApplier.apply(
            for: [robin.id], in: context, watermarks: InMemoryHistoryClearWatermark())

        #expect(try context.fetch(FetchDescriptor<RecentTrailRecord>()).isEmpty)
    }

    /// It runs on every launch and every sync pass, so a second pass has to be free.
    @Test("Applying twice is not different from applying once")
    func idempotent() throws {
        let (context, _, kids) = try store()
        let robin = kids[0]
        search(robin, "gone", at: When.monday, in: context)
        search(robin, "kept", at: When.wednesday, in: context)
        context.insert(
            HistoryClearRecord(kidID: robin.id, clearedThrough: When.tuesday, at: When.tuesday))
        try context.save()

        let marks = InMemoryHistoryClearWatermark()
        let first = HistoryClearApplier.apply(for: [robin.id], in: context, watermarks: marks)
        let second = HistoryClearApplier.apply(for: [robin.id], in: context, watermarks: marks)

        #expect(first == [robin.id])
        // Nothing outstanding the second time, so no work and nothing reported.
        #expect(second.isEmpty)
        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).count == 1)
    }

    @Test("The watermark advances so the next pass does nothing")
    func advancesTheWatermark() throws {
        let (context, _, kids) = try store()
        context.insert(
            HistoryClearRecord(
                kidID: kids[0].id, clearedThrough: When.tuesday, at: When.tuesday))
        try context.save()

        let marks = InMemoryHistoryClearWatermark()
        HistoryClearApplier.apply(for: [kids[0].id], in: context, watermarks: marks)

        #expect(marks.watermark(for: kids[0].id) == When.tuesday)
    }

    /// Order-independence: two instructions settle the same regardless of arrival.
    @Test("Two instructions settle at the furthest, whichever arrives first")
    func arrivalOrderDoesNotMatter() throws {
        for reversed in [false, true] {
            let (context, _, kids) = try store()
            let robin = kids[0]
            search(robin, "monday", at: When.monday, in: context)
            search(robin, "wednesday", at: When.wednesday, in: context)
            search(robin, "thursday", at: When.thursday, in: context)

            var rows = [
                HistoryClearRecord(
                    kidID: robin.id, clearedThrough: When.monday, at: When.monday),
                HistoryClearRecord(
                    kidID: robin.id, clearedThrough: When.wednesday, at: When.wednesday),
            ]
            if reversed { rows.reverse() }
            for row in rows { context.insert(row) }
            try context.save()

            HistoryClearApplier.apply(
                for: [robin.id], in: context, watermarks: InMemoryHistoryClearWatermark())

            let left = try context.fetch(FetchDescriptor<SearchEventRecord>())
            #expect(left.map(\.term) == ["thursday"])
        }
    }

    @Test("A summary made partly of cleared events goes with them")
    func summaryGoes() throws {
        let (context, _, kids) = try store()
        let robin = kids[0]
        let summary = WeeklySummaryRecord(
            weekStart: When.monday, payload: Data(), at: When.monday)
        context.insert(summary)
        robin.attach(summary)
        context.insert(
            HistoryClearRecord(kidID: robin.id, clearedThrough: When.tuesday, at: When.tuesday))
        try context.save()

        HistoryClearApplier.apply(
            for: [robin.id], in: context, watermarks: InMemoryHistoryClearWatermark())

        #expect(try context.fetch(FetchDescriptor<WeeklySummaryRecord>()).isEmpty)
    }
}
