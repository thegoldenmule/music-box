import Foundation
import SwiftData
import Testing

import CatalogKit
import FamilyStore
import PolicyEngine

@testable import KidLibrary

/// A suggestion is the parent's shelf, never the kid's library, by construction.
@Suite("Suggestions stay out of the kid's library")
@MainActor
struct SuggestionSeparation {
    /// Everything a parent can suggest, on one kid.
    private func seeded() throws -> Harness {
        let harness = try Harness()
        harness.kid.addSuggestion(
            target: .catalog(Fix.record), displayName: "The Record", at: Fix.t0
        )
        harness.kid.addSuggestion(
            target: .catalog(Fix.band), displayName: "The Band", at: Fix.t0
        )
        harness.kid.addSuggestion(
            target: .catalog(Fix.clean), displayName: "A Clean Song", at: Fix.t0
        )
        let playlist = harness.kid.addSuggestion(
            target: .snapshotPlaylist(local: UUID()), displayName: "Road Trip", at: Fix.t0
        )
        playlist.addSong(id: Fix.clean, displayName: "A Clean Song", at: Fix.t0)
        try harness.context.save()
        return harness
    }

    @Test("A suggestion is not a favorite")
    func notAFavorite() async throws {
        let harness = try seeded()
        let results = try await harness.library.favorites()

        #expect(results.items.isEmpty)
        // Not merely filtered — absent, unlike a blocked favorite, which shows up.
        #expect(results.blocked.isEmpty)
        #expect(await harness.library.favoriteIDs().isEmpty)
    }

    @Test("A suggested playlist is not one of the kid's playlists")
    func notAPlaylist() async throws {
        let harness = try seeded()
        #expect(await harness.library.playlists().isEmpty)
    }

    @Test("Suggestions are absent from every column of the library browser")
    func notInContents() async throws {
        let harness = try seeded()
        let contents = await harness.library.contents()

        #expect(contents.songs.isEmpty)
        #expect(contents.albums.isEmpty)
        #expect(contents.artists.isEmpty)
        #expect(contents.chosenAlbums.isEmpty)
        #expect(contents.blocked.isEmpty)
    }

    @Test("Searching the library does not find what the parent suggested")
    func notInSearch() async throws {
        let harness = try seeded()
        let results = try await harness.library.searchLibrary("Record")

        #expect(results.items.isEmpty)
        #expect(results.blocked.isEmpty)
    }

    @Test("The parent's review of the library does not show their own suggestions")
    func notInReview() async throws {
        let harness = try seeded()
        // Never policy filtered, so an omission can't read as an engine block.
        let reviewed = await harness.library.reviewed()
        #expect(reviewed.favorites.isEmpty)
        #expect(reviewed.playlists.isEmpty)
    }

    @Test("Favoriting something suggested writes an ordinary favorite, not a second suggestion")
    func favoritingIsSeparate() async throws {
        let harness = try seeded()
        let item = try #require(Fix.catalog.first { $0.id == Fix.clean })

        try await harness.library.addFavorite(item)

        // The kid kept it, so it's theirs — the parent's row is untouched.
        #expect(await harness.library.favoriteIDs() == [Fix.clean])
        #expect(harness.kid.liveSuggestions.count == 4)
        #expect(harness.kid.favorites.count == 1)
    }

    @Test("A suggestion still grants the reach that lets the kid keep it")
    func suggestionMakesItKeepable() async throws {
        // Level 1, empty allow list — the suggestion is the only reach.
        let harness = try Harness(mode: .allowOnly)
        harness.kid.addSuggestion(
            target: .catalog(Fix.clean), displayName: "A Clean Song", at: Fix.t0
        )
        try harness.context.save()

        var rebuilt = harness
        try rebuilt.repolicy { _ in }

        let item = try #require(Fix.catalog.first { $0.id == Fix.clean })
        try await rebuilt.library.addFavorite(item)
        #expect(await rebuilt.library.favoriteIDs() == [Fix.clean])
    }
}
