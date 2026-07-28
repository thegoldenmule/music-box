import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import KidLibrary

/// The admin's read of a kid's shelf.
///
/// Every test here is the same assertion from a different angle: what the kid's
/// screens drop, this keeps. The pair of them is the proof that opening the
/// parent's door did not open the child's.
@Suite("The shelf, unfiltered")
@MainActor
struct Reviewing {
    @Test("A favorite denied since is gone from the shelf and still in the review")
    func deniedFavoriteSurvives() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.band, displayName: "Café Band") }

        // The kid's own read.
        #expect(try await harness.library.favorites().items.isEmpty)

        // The parent's.
        let reviewed = await harness.library.reviewed()
        #expect(reviewed.favorites.count == 1)
        #expect(reviewed.favorites.first?.fact.catalogID == Fix.clean)
        #expect(reviewed.favorites.first?.isAllowedNow == false)
        #expect(reviewed.blockedFavorites.count == 1)
    }

    /// Stage 4's exit test, from this side: an explicit song that reached the
    /// store is off the shelf and present, annotated, in the report.
    @Test("An explicit row adopted into the store shows as unplayable, not as absent")
    func explicitIsVisibleToTheParent() async throws {
        let harness = try Harness()
        // Bypasses the engine deliberately — this is a row that arrived from
        // outside, which is exactly what the Apple provider will do.
        harness.kid.addFavorite(
            id: Fix.explicit,
            displayName: "Swearing",
            origin: .appleLibrary,
            at: Fix.t0
        )
        try harness.context.save()

        #expect(try await harness.library.favorites().items.isEmpty)

        let reviewed = await harness.library.reviewed()
        #expect(reviewed.favorites.count == 1)
        #expect(reviewed.favorites.first?.now == .blocked(.explicitContent))
        #expect(reviewed.favorites.first?.confidence == .exact)
        // And a parent can tell it was adopted rather than chosen.
        #expect(reviewed.adopted.count == 1)
    }

    @Test("Playlist entries are annotated one by one, in the kid's order")
    func playlistEntries() async throws {
        var harness = try Harness()
        let playlist = try await harness.library.createPlaylist(
            named: "Mine",
            songs: [Fix.item(Fix.clean), Fix.item(Fix.other)]
        )
        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.other, displayName: "Something") }

        let reviewed = await harness.library.reviewed()
        let row = try #require(reviewed.playlists.first { $0.id == playlist.handle.local })
        #expect(row.entries.count == 2)
        #expect(row.entries.map(\.fact.catalogID) == [Fix.clean, Fix.other])
        #expect(row.blockedCount == 1)
    }

    @Test("With the catalog down, rows still render and no verdict is invented")
    func offline() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        harness.catalog.isFailing = true

        let reviewed = await harness.library.reviewed()
        #expect(reviewed.favorites.count == 1)
        #expect(reviewed.favorites.first?.fact.displayName == "Sunshine")
        #expect(!reviewed.isResolved)
        // A library row has no rating column to fall back on, so the level 2
        // rating check cannot run — and saying nothing beats reporting our own
        // gap as "they can't play this any more".
        #expect(reviewed.favorites.first?.confidence == .unknown)
        #expect(reviewed.favorites.first?.now == nil)
    }

    @Test("A deny still bites with the catalog down")
    func offlineDenyStillBites() async throws {
        var harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        try harness.repolicy { $0.addEntry(kind: .deny, id: Fix.clean, displayName: "Sunshine") }
        harness.catalog.isFailing = true

        let reviewed = await harness.library.reviewed()
        #expect(reviewed.favorites.first?.now == .blocked(.deniedByParent(Fix.clean)))
        #expect(reviewed.favorites.first?.confidence == .exact)
    }

    @Test("A delisted row is counted as unresolved rather than dropped")
    func delisted() async throws {
        let harness = try Harness()
        try await harness.library.addFavorite(Fix.item(Fix.clean))
        harness.catalog.delist(Fix.clean)

        let reviewed = await harness.library.reviewed()
        #expect(reviewed.favorites.count == 1)
        #expect(reviewed.unresolved == 1)
        #expect(reviewed.isResolved)
    }
}

// MARK: -

@Suite("Where a shelf came from")
@MainActor
struct ProviderReporting {
    @Test("Every configured provider is reported, live or not")
    func livenessIsReported() async throws {
        let harness = try Harness(extra: [StubProvider()])
        let reviewed = await harness.library.reviewed()
        #expect(reviewed.providers[.cloudKit] == .live)
        #expect(reviewed.providers[.appleMusic] == .live)
    }

    @Test("A shared device is reported as an answer the parent gave, not a fault")
    func sharedDevice() async throws {
        let harness = try Harness(
            extra: [StubProvider()],
            device: .asked(shared: true)
        )
        let reviewed = await harness.library.reviewed()
        #expect(reviewed.providers[.appleMusic] == .notConfigured(.sharedDevice))
    }

    @Test("Before onboarding asks, the Apple library is not read and says so")
    func notYetAsked() async throws {
        let harness = try Harness(extra: [StubProvider()], device: .unasked)
        let reviewed = await harness.library.reviewed()
        #expect(reviewed.providers[.appleMusic] == .notConfigured(.notYetAsked))
    }

    /// The kid's side swallows this and says nothing. A short shelf and a broken
    /// read look identical, and only one of them is about the child.
    @Test("A provider that throws is reported to the parent")
    func failureIsReported() async throws {
        let provider = StubProvider()
        provider.isFailing = true
        let harness = try Harness(extra: [provider])

        let reviewed = await harness.library.reviewed()
        guard case .failed = reviewed.providers[.appleMusic] else {
            Issue.record("expected a failure, got \(String(describing: reviewed.providers[.appleMusic]))")
            return
        }
        // And it did not empty the shelf.
        #expect(reviewed.providers[.cloudKit] == .live)
    }
}
