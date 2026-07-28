import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

/// One real session, pulled off a device.
///
/// Twenty-three arrivals: an evening on one record by Foehn Trio, then a jump to
/// The Killers. It is here verbatim because the shelf it produced on the device
/// disagreed with the shelf ``RecentTrail/shelf(from:)`` computes from the same
/// rows — the rules were right and the thing maintaining the stored copy was
/// not, which is a class of bug no amount of testing the rules would have found.
private enum Device {
    static let foehn = CatalogID(.artist, "1231820400")
    static let highlines = CatalogID(.album, "1502196500")
    static let wolves = CatalogID(.song, "1502196507")
    static let laBarma = CatalogID(.song, "1502196699")
    static let laVengeance = CatalogID(.song, "1502196722")

    static let killers = CatalogID(.artist, "6483093")
    static let hotFuss = CatalogID(.album, "1526194184")
    static let jenny = CatalogID(.song, "1526194191")
    static let brightside = CatalogID(.song, "1526194192")

    /// `at` values exactly as stored, so the runs segment the way they did.
    static let visits: [VisitEvent] = [
        v(foehn, 806_947_921.546789, "Foehn Trio"),
        v(highlines, 806_947_922.928347, "Highlines", artist: foehn),
        v(highlines, 806_948_196.972850, "Highlines", artist: foehn),
        v(wolves, 806_948_199.169656, "Wolves", album: highlines, artist: foehn),
        v(laBarma, 806_948_582.853441, "La Barma", album: highlines, artist: foehn),
        v(laBarma, 806_948_791.040391, "La Barma", album: highlines, artist: foehn),
        v(wolves, 806_953_738.681384, "Wolves", album: highlines, artist: foehn),
        v(highlines, 806_953_772.251700, "Highlines", artist: foehn),
        v(wolves, 806_953_774.411165, "Wolves", album: highlines, artist: foehn),
        v(highlines, 806_953_850.909970, "Highlines", artist: foehn),
        v(highlines, 806_953_853.571385, "Highlines", artist: foehn),
        v(highlines, 806_953_859.366154, "Highlines", artist: foehn),
        v(highlines, 806_953_863.768647, "Highlines", artist: foehn),
        v(highlines, 806_953_865.936763, "Highlines", artist: foehn),
        v(highlines, 806_953_944.126612, "Highlines", artist: foehn),
        v(wolves, 806_953_946.267747, "Wolves", album: highlines, artist: foehn),
        v(highlines, 806_954_040.013661, "Highlines", artist: foehn),
        v(laVengeance, 806_954_042.670843, "La vengeance", album: highlines, artist: foehn),
        v(killers, 806_954_049.675045, "The Killers"),
        v(hotFuss, 806_954_052.241400, "Hot Fuss", artist: killers),
        v(jenny, 806_954_054.488070, "Jenny Was a Friend of Mine", album: hotFuss, artist: killers),
        v(killers, 806_954_057.022399, "The Killers"),
        v(brightside, 806_954_316.847151, "Mr. Brightside", album: hotFuss, artist: killers),
    ]

    private static func v(
        _ id: CatalogID,
        _ at: TimeInterval,
        _ name: String,
        album: CatalogID? = nil,
        artist: CatalogID? = nil
    ) -> VisitEvent {
        VisitEvent(
            itemID: id,
            displayName: name,
            albumID: album,
            artistID: artist,
            manner: id.kind == .song ? .played : .opened,
            at: Date(timeIntervalSinceReferenceDate: at)
        )
    }
}

@MainActor
private func storeWithKid() throws -> (ModelContainer, UUID) {
    let container = try FamilyStore.inMemoryContainer()
    let context = ModelContext(container)
    let family = Family()
    let kid = Kid(name: "Robin", mode: .denyPlusAuto)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid)
    try context.save()
    return (container, kid.id)
}

@Suite("A real session off a device")
struct DeviceSession {
    /// What the rules say, computed in one go. Both records, and neither artist
    /// — Foehn Trio is represented by Highlines and The Killers by Hot Fuss.
    /// Mr. Brightside is dropped because Hot Fuss is the way back to it.
    @Test("The rules produce both records and no artist")
    func rulesAreRight() {
        let shelf = RecentTrail.shelf(from: Device.visits).map(\.catalogID)
        #expect(shelf == [Device.hotFuss, Device.highlines])
    }

    /// **The bug this file exists for.** On the device the stored shelf was
    /// `[Hot Fuss, The Killers, Highlines]` with Highlines stamped four minutes
    /// stale — a state no single run of the rules can produce. Feeding the
    /// arrivals in one at a time, the way they actually happened, has to leave
    /// exactly what computing them all at once does.
    @Test("Arriving one at a time leaves the same shelf as computing it at once")
    func incrementalMatchesWholesale() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)

        var last: [RecentEntry] = []
        for visit in Device.visits {
            last = try await projector.record(visit, for: kidID)
        }

        #expect(last.map(\.catalogID) == [Device.hotFuss, Device.highlines])

        // And the store agrees with what was handed back, which is the half the
        // device disproved: the shelf a kid sees comes from memory, and the one
        // they see after a relaunch comes from here.
        let stored = try await projector.trail(for: kidID)
        #expect(stored.map(\.catalogID) == [Device.hotFuss, Device.highlines])
    }

    /// The device's shelf was wrong and nothing was ever going to notice: a
    /// missed write leaves rows that are stale in *content*, and staleness used
    /// to be judged by version alone. Reading the shelf now recomputes it, so a
    /// relaunch is enough to heal one.
    @Test("A wrong shelf heals on the next read")
    func readHeals() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)
        for visit in Device.visits {
            try await projector.record(visit, for: kidID)
        }

        // Exactly what the device had: a row the rules forbid, at the current
        // version so no version check could catch it.
        try await MainActor.run {
            let context = ModelContext(container)
            let kid = try #require(
                try context.fetch(FetchDescriptor<Kid>(predicate: #Predicate { $0.id == kidID }))
                    .first
            )
            let stray = RecentTrailRecord(
                entry: RecentEntry(
                    catalogID: Device.killers,
                    displayName: "The Killers",
                    at: Date(timeIntervalSinceReferenceDate: 806_954_049)
                )
            )
            context.insert(stray)
            kid.attach(stray)
            try context.save()
        }

        let healed = try await projector.trail(for: kidID)
        #expect(healed.map(\.catalogID) == [Device.hotFuss, Device.highlines])
    }

    @Test("No stale rows survive the run")
    func noStragglers() async throws {
        let (container, kidID) = try await storeWithKid()
        let projector = RecentsProjector(modelContainer: container)
        for visit in Device.visits {
            try await projector.record(visit, for: kidID)
        }

        try await MainActor.run {
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<RecentTrailRecord>())
            #expect(rows.count == 2)
            // The artist row that was left behind on the device.
            #expect(!rows.contains { $0.catalogID == Device.killers.rawValue })
        }
    }
}
