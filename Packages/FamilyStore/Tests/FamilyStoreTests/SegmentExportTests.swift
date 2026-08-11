import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let song = CatalogID(.song, "song-A")
    static let album = CatalogID(.album, "album-A")
    static let artist = CatalogID(.artist, "artist-A")

    /// 2023-11-14T22:13:20Z — deliberately late in the UTC day, so a device east of
    /// UTC would put it on the 15th and the grouping test means something.
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let nextDay = t0.addingTimeInterval(86_400)

    static let deviceA = UUID()
    static let deviceB = UUID()
}

@MainActor
private func storeWithKid() throws -> (ModelContainer, ModelContext, Kid) {
    let container = try FamilyStore.inMemoryContainer()
    let context = ModelContext(container)
    let family = Family(at: Fix.t0)
    let kid = Kid(name: "Robin", mode: .denyPlusAuto, at: Fix.t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.t0)
    try context.save()
    return (container, context, kid)
}

@MainActor
private func addSearch(_ kid: Kid, _ term: String, at: Date, in context: ModelContext) {
    let row = SearchEventRecord(
        event: SearchEvent(
            term: term, at: at, resultCount: 3, blockedCount: 1, gaveUpEarly: false))
    context.insert(row)
    kid.attach(row)
}

@MainActor
private func addPlay(_ kid: Kid, seconds: Int, at: Date, in context: ModelContext) {
    let row = PlayEventRecord(
        event: PlayEvent(
            songID: Fix.song,
            albumID: Fix.album,
            artistID: Fix.artist,
            displayName: "A Song",
            rating: .clean,
            at: at,
            secondsPlayed: seconds,
            origin: .search(term: "dinosaurs")
        ))
    context.insert(row)
    kid.attach(row)
}

@MainActor
private func addBlock(_ kid: Kid, at: Date, in context: ModelContext) {
    let row = BlockEventRecord(
        event: BlockEvent(
            itemID: Fix.song,
            displayName: "A Rude Song",
            artistID: Fix.artist,
            rating: .explicit,
            at: at,
            reach: .unseen,
            reason: .deniedByParent(Fix.artist),
            origin: .browse(Fix.album)
        ))
    context.insert(row)
    kid.attach(row)
}

// MARK: -

@Suite("What a segment payload carries")
struct ThePayload {
    /// Every field, because these bytes are read back months later by a build that
    /// may not have written them, and a field lost in encoding is a field a parent's
    /// report silently stops showing.
    @Test("A play round-trips every field, origin included")
    func playRoundTrips() throws {
        let event = PlayEvent(
            songID: Fix.song,
            albumID: Fix.album,
            artistID: Fix.artist,
            displayName: "A Song",
            rating: .unrated,
            at: Fix.t0,
            secondsPlayed: 91,
            origin: .kidPlaylist(UUID())
        )
        let data = try JSONEncoder().encode(
            ActivitySegment(rows: [ActivitySegment.Row(id: UUID(), play: event)]))
        let back = try JSONDecoder().decode(ActivitySegment.self, from: data)
        #expect(back.rows.first?.play == event)
    }

    /// `BlockReason` and `PlaybackOrigin` both carry associated values and both route
    /// through their frozen stored form rather than a synthesised shape.
    @Test("A block round-trips its reason and its reach")
    func blockRoundTrips() throws {
        let event = BlockEvent(
            itemID: Fix.song,
            displayName: "A Rude Song",
            artistID: Fix.artist,
            rating: .explicit,
            at: Fix.t0,
            reach: .reached,
            reason: .deniedByParent(Fix.artist),
            origin: .search(term: "rude")
        )
        let data = try JSONEncoder().encode(
            ActivitySegment(rows: [ActivitySegment.Row(id: UUID(), block: event)]))
        let back = try JSONDecoder().decode(ActivitySegment.self, from: data)
        #expect(back.rows.first?.block == event)
    }

    /// The one field the maintainer decided stays through compaction. It is also the
    /// most sensitive thing this store holds, so an encoding that quietly dropped it
    /// would be both a loss and a false reassurance.
    @Test("A search keeps its raw term")
    func searchKeepsTheTerm() throws {
        let event = SearchEvent(
            term: "why do dogs bark", at: Fix.t0, resultCount: 4, blockedCount: 2,
            gaveUpEarly: true)
        let data = try JSONEncoder().encode(
            ActivitySegment(rows: [ActivitySegment.Row(id: UUID(), search: event)]))
        let back = try JSONDecoder().decode(ActivitySegment.self, from: data)
        #expect(back.rows.first?.search?.term == "why do dogs bark")
        #expect(back.rows.first?.search?.gaveUpEarly == true)
    }

    /// **The wire is frozen even though the property names are not.** If this breaks,
    /// somebody renamed a field and every segment already written became unreadable.
    @Test("The keys on the wire are the frozen short ones")
    func keysAreFrozen() throws {
        let data = try JSONEncoder().encode(
            ActivitySegment(rows: [
                ActivitySegment.Row(
                    id: UUID(),
                    search: SearchEvent(
                        term: "x", at: Fix.t0, resultCount: 0, blockedCount: 0,
                        gaveUpEarly: false))
            ]))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"ver\""))
        #expect(json.contains("\"t\":\"x\""))
        #expect(!json.contains("resultCount"))
    }
}

// MARK: -

@Suite("Packing a device's own events")
@MainActor
struct Packing {
    @Test("Events with no export yet are packed and stamped")
    func packsAndStamps() throws {
        let (_, context, kid) = try storeWithKid()
        addSearch(kid, "dinosaurs", at: Fix.t0, in: context)
        addPlay(kid, seconds: 60, at: Fix.t0, in: context)
        try context.save()

        let written = SegmentExport.pack(
            for: [kid.id], deviceID: Fix.deviceA, in: context, at: Fix.t0)

        #expect(written == 2)  // one per table
        let searches = try context.fetch(FetchDescriptor<SearchEventRecord>())
        #expect(searches.allSatisfy { $0.exportedAt != nil })
    }

    /// Otherwise every sync pass re-exports a child's whole history.
    @Test("Packing twice writes nothing the second time")
    func idempotent() throws {
        let (_, context, kid) = try storeWithKid()
        addSearch(kid, "dinosaurs", at: Fix.t0, in: context)
        try context.save()

        _ = SegmentExport.pack(for: [kid.id], deviceID: Fix.deviceA, in: context, at: Fix.t0)
        let second = SegmentExport.pack(
            for: [kid.id], deviceID: Fix.deviceA, in: context, at: Fix.t0)

        #expect(second == 0)
        #expect(try context.fetch(FetchDescriptor<ActivitySegmentRecord>()).count == 1)
    }

    /// The day is part of the record key, so two devices in two time zones have to
    /// agree which day a row belongs to.
    @Test("Two days are two segments, keyed by UTC day")
    func splitsByDay() throws {
        let (_, context, kid) = try storeWithKid()
        addSearch(kid, "monday", at: Fix.t0, in: context)
        addSearch(kid, "tuesday", at: Fix.nextDay, in: context)
        try context.save()

        SegmentExport.pack(for: [kid.id], deviceID: Fix.deviceA, in: context, at: Fix.t0)

        let days = Set(
            try context.fetch(FetchDescriptor<ActivitySegmentRecord>()).map(\.dayUTC))
        #expect(days.count == 2)
        #expect(days.contains("2023-11-14"))
        #expect(days.contains("2023-11-15"))
    }

    /// `index` exists so a day is a sequence rather than one object, which is what
    /// makes an interrupted export resumable.
    @Test("A day longer than one segment is indexed in order")
    func chunksAndIndexes() throws {
        let (_, context, kid) = try storeWithKid()
        for i in 0..<(SegmentExport.rowsPerSegment + 10) {
            addSearch(kid, "term \(i)", at: Fix.t0.addingTimeInterval(Double(i)), in: context)
        }
        try context.save()

        SegmentExport.pack(for: [kid.id], deviceID: Fix.deviceA, in: context, at: Fix.t0)

        let segments = try context.fetch(FetchDescriptor<ActivitySegmentRecord>())
        #expect(segments.count == 2)
        #expect(Set(segments.map(\.index)) == [0, 1])
    }

    /// A device that exported half a day yesterday continues the sequence, so an
    /// existing segment is never overwritten by one holding different rows.
    @Test("A later export resumes the index rather than restarting it")
    func resumesIndex() throws {
        let (_, context, kid) = try storeWithKid()
        addSearch(kid, "first", at: Fix.t0, in: context)
        try context.save()
        SegmentExport.pack(for: [kid.id], deviceID: Fix.deviceA, in: context, at: Fix.t0)

        addSearch(kid, "second", at: Fix.t0.addingTimeInterval(60), in: context)
        try context.save()
        SegmentExport.pack(for: [kid.id], deviceID: Fix.deviceA, in: context, at: Fix.t0)

        let indexes = try context.fetch(FetchDescriptor<ActivitySegmentRecord>())
            .filter { $0.dayUTC == "2023-11-14" && $0.table == "searches" }
            .map(\.index)
        #expect(indexes.sorted() == [0, 1])
    }

    @Test("Another kid's events are not packed into this kid's segments")
    func perKid() throws {
        let (_, context, kid) = try storeWithKid()
        let other = Kid(name: "Sam", mode: .denyPlusAuto, at: Fix.t0)
        context.insert(other)
        addSearch(kid, "robin's", at: Fix.t0, in: context)
        addSearch(other, "sam's", at: Fix.t0, in: context)
        try context.save()

        SegmentExport.pack(for: [kid.id], deviceID: Fix.deviceA, in: context, at: Fix.t0)

        let segments = try context.fetch(FetchDescriptor<ActivitySegmentRecord>())
        #expect(segments.count == 1)
        #expect(segments.first?.kidID == kid.id)
    }
}

// MARK: -

/// Two stores standing in for two devices. This is the half that did not exist:
/// arriving segments were stored and never read, so a co-parent accumulated opaque
/// blobs and their report was empty.
@Suite("Absorbing another device's segments")
@MainActor
struct Absorbing {
    /// Moves the segment rows across without moving the event rows, which is exactly
    /// what sync does — the event tables are in `neverSyncs`.
    private func ship(
        from source: ModelContext, to destination: ModelContext, kid: Kid
    ) throws {
        for segment in try source.fetch(FetchDescriptor<ActivitySegmentRecord>()) {
            destination.insert(
                ActivitySegmentRecord(
                    id: segment.id,
                    kidID: segment.kidID,
                    deviceID: segment.deviceID,
                    dayUTC: segment.dayUTC,
                    table: segment.table,
                    index: segment.index,
                    payload: segment.payload,
                    at: Fix.t0
                )
            )
        }
        try destination.save()
    }

    @Test("A co-parent's device materialises the events it was sent")
    func absorbs() throws {
        let (_, kidsDevice, robinThere) = try storeWithKid()
        addSearch(robinThere, "dinosaurs", at: Fix.t0, in: kidsDevice)
        addPlay(robinThere, seconds: 120, at: Fix.t0, in: kidsDevice)
        addBlock(robinThere, at: Fix.t0, in: kidsDevice)
        try kidsDevice.save()
        SegmentExport.pack(
            for: [robinThere.id], deviceID: Fix.deviceA, in: kidsDevice, at: Fix.t0)

        // The parent's phone: same kid, none of the events.
        let parents = ModelContext(try FamilyStore.inMemoryContainer())
        let family = Family(at: Fix.t0)
        let robinHere = Kid(id: robinThere.id, name: "Robin", mode: .denyPlusAuto, at: Fix.t0)
        parents.insert(family)
        parents.insert(robinHere)
        family.addKid(robinHere, at: Fix.t0)
        try parents.save()
        try ship(from: kidsDevice, to: parents, kid: robinHere)

        let inserted = SegmentExport.unpack(
            for: [robinHere.id], deviceID: Fix.deviceB, in: parents)

        #expect(inserted == 3)
        #expect(try parents.fetch(FetchDescriptor<SearchEventRecord>()).count == 1)
        #expect(try parents.fetch(FetchDescriptor<PlayEventRecord>()).count == 1)
        let block = try parents.fetch(FetchDescriptor<BlockEventRecord>()).first
        #expect(block?.event?.reason == .deniedByParent(Fix.artist))
        #expect(block?.event?.reach == .unseen)
    }

    /// The forensic column is worthless if absorbing rewrites it to whoever imported
    /// the row.
    @Test("An absorbed row keeps the device that originally wrote it")
    func keepsOriginatingDevice() throws {
        let (_, kidsDevice, robinThere) = try storeWithKid()
        addSearch(robinThere, "dinosaurs", at: Fix.t0, in: kidsDevice)
        try kidsDevice.save()
        SegmentExport.pack(
            for: [robinThere.id], deviceID: Fix.deviceA, in: kidsDevice, at: Fix.t0)

        let parents = ModelContext(try FamilyStore.inMemoryContainer())
        let family = Family(at: Fix.t0)
        let robinHere = Kid(id: robinThere.id, name: "Robin", mode: .denyPlusAuto, at: Fix.t0)
        parents.insert(family)
        parents.insert(robinHere)
        family.addKid(robinHere, at: Fix.t0)
        try parents.save()
        try ship(from: kidsDevice, to: parents, kid: robinHere)

        SegmentExport.unpack(for: [robinHere.id], deviceID: Fix.deviceB, in: parents)

        let row = try parents.fetch(FetchDescriptor<SearchEventRecord>()).first
        #expect(row?.originatingDeviceID == Fix.deviceA)
    }

    /// This runs on every sync pass, so a second pass has to cost nothing — and a
    /// re-export under a churned device identity has to be harmless.
    @Test("Absorbing twice inserts nothing the second time")
    func idempotent() throws {
        let (_, kidsDevice, robinThere) = try storeWithKid()
        addSearch(robinThere, "dinosaurs", at: Fix.t0, in: kidsDevice)
        try kidsDevice.save()
        SegmentExport.pack(
            for: [robinThere.id], deviceID: Fix.deviceA, in: kidsDevice, at: Fix.t0)

        let parents = ModelContext(try FamilyStore.inMemoryContainer())
        let family = Family(at: Fix.t0)
        let robinHere = Kid(id: robinThere.id, name: "Robin", mode: .denyPlusAuto, at: Fix.t0)
        parents.insert(family)
        parents.insert(robinHere)
        family.addKid(robinHere, at: Fix.t0)
        try parents.save()
        try ship(from: kidsDevice, to: parents, kid: robinHere)

        let first = SegmentExport.unpack(for: [robinHere.id], deviceID: Fix.deviceB, in: parents)
        let second = SegmentExport.unpack(for: [robinHere.id], deviceID: Fix.deviceB, in: parents)

        #expect(first == 1)
        #expect(second == 0)
        #expect(try parents.fetch(FetchDescriptor<SearchEventRecord>()).count == 1)
    }

    /// A device's own segments describe rows it already has. Absorbing them would
    /// duplicate its history against itself.
    @Test("A device does not absorb its own segments")
    func skipsOwn() throws {
        let (_, context, kid) = try storeWithKid()
        addSearch(kid, "dinosaurs", at: Fix.t0, in: context)
        try context.save()
        SegmentExport.pack(for: [kid.id], deviceID: Fix.deviceA, in: context, at: Fix.t0)

        let inserted = SegmentExport.unpack(for: [kid.id], deviceID: Fix.deviceA, in: context)

        #expect(inserted == 0)
        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).count == 1)
    }

    /// **Kept and skipped, never dropped.** The device that wrote it still has the
    /// rows, and a later build here will read it; deleting would lose a child's
    /// history to a version check.
    @Test("A segment from a newer build is left alone rather than discarded")
    func futureVersionIsKept() throws {
        let (_, context, kid) = try storeWithKid()
        let payload = try JSONEncoder().encode(
            ActivitySegment(
                rows: [
                    ActivitySegment.Row(
                        id: UUID(),
                        search: SearchEvent(
                            term: "x", at: Fix.t0, resultCount: 0, blockedCount: 0,
                            gaveUpEarly: false))
                ],
                version: ActivitySegment.version + 1
            ))
        context.insert(
            ActivitySegmentRecord(
                kidID: kid.id, deviceID: Fix.deviceA, dayUTC: "2023-11-14",
                table: "searches", index: 0, payload: payload, at: Fix.t0))
        try context.save()

        let inserted = SegmentExport.unpack(for: [kid.id], deviceID: Fix.deviceB, in: context)

        #expect(inserted == 0)
        #expect(try context.fetch(FetchDescriptor<SearchEventRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ActivitySegmentRecord>()).count == 1)
    }
}

// MARK: -

/// The interlock between the two halves of Stage 7. A clear reaches rows that had
/// not arrived when it was issued, and a segment written by a device that had not
/// heard about it yet is exactly that case.
@Suite("Absorbing does not resurrect cleared history")
@MainActor
struct ClearedRowsStayGone {
    private func parentsPhone(kidID: UUID) throws -> (ModelContext, Kid) {
        let context = ModelContext(try FamilyStore.inMemoryContainer())
        let family = Family(at: Fix.t0)
        let kid = Kid(id: kidID, name: "Robin", mode: .denyPlusAuto, at: Fix.t0)
        context.insert(family)
        context.insert(kid)
        family.addKid(kid, at: Fix.t0)
        try context.save()
        return (context, kid)
    }

    /// Without the boundary check this comes back on the co-parent's phone, which is
    /// the device nobody is looking at.
    @Test("A segment holding rows a clear destroyed is absorbed as nothing")
    func clearedRowsAreSkipped() throws {
        let (_, kidsDevice, robinThere) = try storeWithKid()
        addSearch(robinThere, "before the clear", at: Fix.t0, in: kidsDevice)
        try kidsDevice.save()
        SegmentExport.pack(
            for: [robinThere.id], deviceID: Fix.deviceA, in: kidsDevice, at: Fix.t0)

        let (parents, robinHere) = try parentsPhone(kidID: robinThere.id)
        // The parent cleared on their own phone, then the kid's segment turns up.
        robinHere.deleteHistory(at: Fix.t0.addingTimeInterval(60))
        for segment in try kidsDevice.fetch(FetchDescriptor<ActivitySegmentRecord>()) {
            parents.insert(
                ActivitySegmentRecord(
                    id: segment.id, kidID: segment.kidID, deviceID: segment.deviceID,
                    dayUTC: segment.dayUTC, table: segment.table, index: segment.index,
                    payload: segment.payload, at: Fix.t0))
        }
        try parents.save()

        let inserted = SegmentExport.unpack(
            for: [robinHere.id], deviceID: Fix.deviceB, in: parents)

        #expect(inserted == 0)
        #expect(try parents.fetch(FetchDescriptor<SearchEventRecord>()).isEmpty)
    }

    /// A clear is bounded, so it must not swallow what came after it.
    @Test("Rows after the boundary still arrive")
    func laterRowsStillArrive() throws {
        let (_, kidsDevice, robinThere) = try storeWithKid()
        addSearch(robinThere, "after the clear", at: Fix.nextDay, in: kidsDevice)
        try kidsDevice.save()
        SegmentExport.pack(
            for: [robinThere.id], deviceID: Fix.deviceA, in: kidsDevice, at: Fix.nextDay)

        let (parents, robinHere) = try parentsPhone(kidID: robinThere.id)
        robinHere.deleteHistory(at: Fix.t0)
        for segment in try kidsDevice.fetch(FetchDescriptor<ActivitySegmentRecord>()) {
            parents.insert(
                ActivitySegmentRecord(
                    id: segment.id, kidID: segment.kidID, deviceID: segment.deviceID,
                    dayUTC: segment.dayUTC, table: segment.table, index: segment.index,
                    payload: segment.payload, at: Fix.t0))
        }
        try parents.save()

        let inserted = SegmentExport.unpack(
            for: [robinHere.id], deviceID: Fix.deviceB, in: parents)

        #expect(inserted == 1)
        #expect(
            try parents.fetch(FetchDescriptor<SearchEventRecord>()).first?.event.term
                == "after the clear")
    }
}
