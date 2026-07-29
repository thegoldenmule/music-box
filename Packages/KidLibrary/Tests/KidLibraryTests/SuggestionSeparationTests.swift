import Foundation
import SwiftData
import Testing

import CatalogKit
import FamilyStore
import PolicyEngine

@testable import KidLibrary

/// **A suggestion is the parent's shelf, and never the kid's library.**
///
/// The two live in the same store, on the same `Kid`, and are read by code that
/// sits a few lines apart. What keeps them separate is that `MergedLibrary` reads
/// through `LibraryProvider` and no provider has ever heard of a suggestion —
/// which is an argument about code that is one refactor away from being wrong.
/// These are the tests that would notice.
///
/// The failure they guard against is not a crash. It is a parent's picks
/// quietly appearing on the shelf labelled with the child's own name, which is
/// the one thing the Library shelf was renamed to stop the app doing.
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
        // Not merely filtered out — absent. A blocked favorite would show up in
        // `blocked` with its reason, and a suggestion must not be there either.
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
        // This one is never policy filtered, so an omission here cannot be
        // mistaken for the engine having turned something down.
        let reviewed = await harness.library.reviewed()
        #expect(reviewed.favorites.isEmpty)
        #expect(reviewed.playlists.isEmpty)
    }

    @Test("Favoriting something suggested writes an ordinary favorite, not a second suggestion")
    func favoritingIsSeparate() async throws {
        let harness = try seeded()
        let item = try #require(Fix.catalog.first { $0.id == Fix.clean })

        try await harness.library.addFavorite(item)

        // The kid kept it, so it is theirs now — and the parent's row is
        // untouched, still listed as suggested and still granting its allow.
        #expect(await harness.library.favoriteIDs() == [Fix.clean])
        #expect(harness.kid.liveSuggestions.count == 4)
        #expect(harness.kid.favorites.count == 1)
    }

    @Test("A suggestion still grants the reach that lets the kid keep it")
    func suggestionMakesItKeepable() async throws {
        // Level 1 with an empty allow list reaches nothing, so this is the
        // sharpest version of the question: the *only* thing making the song
        // favoritable is the suggestion.
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
