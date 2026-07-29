import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

// MARK: - Fixtures

private enum Fix {
    static let artist = CatalogID(.artist, "artist-A")
    static let album = CatalogID(.album, "album-A")
    static let song = CatalogID(.song, "song-A")
    static let song2 = CatalogID(.song, "song-B")
    static let explicitSong = CatalogID(.song, "song-X")
    static let catalogPlaylist = CatalogID(.playlist, "playlist-A")

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_700_086_400)
    static let t2 = Date(timeIntervalSince1970: 1_700_172_800)

    /// A song on `album`, by `artist` — the lineage a snapshot entry has to
    /// carry for the player to be able to queue it.
    static let ancestry = LibraryAncestry(
        albumID: album.rawValue,
        albumName: "An Album",
        artistID: artist.rawValue,
        artistName: "An Artist"
    )
}

@MainActor
private func newKid(mode: SandboxMode = .denyPlusAuto) throws -> (ModelContext, Kid) {
    let context = ModelContext(try FamilyStore.inMemoryContainer())
    let family = Family(at: Fix.t0)
    let kid = Kid(name: "Robin", mode: mode, at: Fix.t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.t0)
    return (context, kid)
}

// MARK: - Storage

@Suite("Suggestions")
@MainActor
struct Suggestions {
    @Test("A suggestion round-trips through storage as a row")
    func roundTrips() throws {
        let (context, kid) = try newKid()
        kid.addSuggestion(
            target: .catalog(Fix.album),
            displayName: "An Album",
            subtitle: "An Artist",
            artworkURL: URL(string: "https://example.invalid/a.jpg"),
            note: "You liked the other one",
            at: Fix.t0
        )
        try context.save()

        let row = try #require(kid.liveSuggestions.first)
        #expect(row.target == .catalog(Fix.album))
        #expect(row.catalogID == Fix.album)
        #expect(row.itemKind == .album)
        #expect(row.displayName == "An Album")
        #expect(row.subtitle == "An Artist")
        #expect(row.note == "You liked the other one")
        #expect(row.suggestedAt == Fix.t0)
        #expect(row.isDismissed == false)
    }

    @Test("Suggesting the same item twice makes one row, not two")
    func upserts() throws {
        let (_, kid) = try newKid()
        kid.addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0)
        kid.addSuggestion(target: .catalog(Fix.album), displayName: "An Album (Deluxe)", at: Fix.t1)

        #expect(kid.suggestions.count == 1)
        #expect(kid.liveSuggestions.first?.displayName == "An Album (Deluxe)")
    }

    @Test("Re-suggesting something still on the shelf does not reshuffle it")
    func refreshKeepsPosition() throws {
        let (_, kid) = try newKid()
        kid.addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0)
        kid.addSuggestion(target: .catalog(Fix.artist), displayName: "An Artist", at: Fix.t1)

        // The album is behind the artist, and suggesting it again — a parent
        // forgetting they already did — must not push it back in front.
        kid.addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t2)

        #expect(kid.liveSuggestions.map(\.displayName) == ["An Artist", "An Album"])
        #expect(kid.liveSuggestions.last?.suggestedAt == Fix.t0)
    }

    @Test("The shelf reads newest first")
    func newestFirst() throws {
        let (_, kid) = try newKid()
        kid.addSuggestion(target: .catalog(Fix.album), displayName: "First", at: Fix.t0)
        kid.addSuggestion(target: .catalog(Fix.artist), displayName: "Second", at: Fix.t1)
        kid.addSuggestion(target: .catalog(Fix.song), displayName: "Third", at: Fix.t2)

        #expect(kid.liveSuggestions.map(\.displayName) == ["Third", "Second", "First"])
    }

    @Test("Inserting a suggestion does not touch the rows already there")
    func insertDoesNotChurn() throws {
        let (_, kid) = try newKid()
        let first = kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "First", at: Fix.t0
        )
        kid.addSuggestion(target: .catalog(Fix.artist), displayName: "Second", at: Fix.t1)

        // Making room at the front by shifting every position would stamp every
        // `modifiedAt` and churn the rows sync most wants quiet.
        #expect(first.modifiedAt == Fix.t0)
        #expect(first.position == 0)
    }

    @Test("A dismissed suggestion leaves the shelf and shows up as passed on")
    func dismissal() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0
        )
        kid.dismissSuggestion(record, at: Fix.t1)

        #expect(kid.liveSuggestions.isEmpty)
        #expect(kid.dismissedSuggestions.map(\.displayName) == ["An Album"])
        #expect(kid.dismissedSuggestions.first?.dismissedAt == Fix.t1)
    }

    @Test("Dismissing stamps modifiedAt, unlike the kid's other writes")
    func dismissalStampsModified() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0
        )
        kid.dismissSuggestion(record, at: Fix.t1)

        // A dismissal withdraws an allow. Losing that to a sync merge would put
        // the item back in front of the child.
        #expect(record.modifiedAt == Fix.t1)
    }

    @Test("Re-suggesting something passed on brings it back, at the front")
    func restore() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0
        )
        kid.dismissSuggestion(record, at: Fix.t1)
        kid.addSuggestion(target: .catalog(Fix.artist), displayName: "An Artist", at: Fix.t1)
        kid.addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t2)

        #expect(kid.dismissedSuggestions.isEmpty)
        #expect(kid.liveSuggestions.map(\.displayName) == ["An Album", "An Artist"])
        #expect(kid.liveSuggestions.first?.suggestedAt == Fix.t2)
    }

    @Test("A refresh without a note does not erase the one already written")
    func refreshKeepsNote() throws {
        let (_, kid) = try newKid()
        kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "An Album", note: "Try this", at: Fix.t0
        )
        kid.addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t1)

        #expect(kid.liveSuggestions.first?.note == "Try this")
    }

    @Test("Withdrawing a suggestion deletes the row rather than orphaning it")
    func withdrawDeletes() throws {
        let (context, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0
        )
        try context.save()

        kid.removeSuggestion(record, at: Fix.t1)
        try context.save()

        #expect(kid.suggestions.isEmpty)
        let all = try context.fetch(FetchDescriptor<SuggestionRecord>())
        #expect(all.isEmpty, "removeAll() alone would leave the row on disk, invisible")
    }
}

// MARK: - Snapshot playlists

@Suite("Suggested playlists")
@MainActor
struct SuggestedPlaylists {
    @Test("A snapshot playlist keeps its songs in order")
    func snapshotOrder() throws {
        let (context, kid) = try newKid()
        let local = UUID()
        let record = kid.addSuggestion(
            target: .snapshotPlaylist(local: local),
            displayName: "Road Trip 2019",
            at: Fix.t0
        )
        record.addSong(id: Fix.song, displayName: "One", ancestry: Fix.ancestry, at: Fix.t0)
        record.addSong(id: Fix.song2, displayName: "Two", ancestry: Fix.ancestry, at: Fix.t0)
        try context.save()

        let row = try #require(kid.liveSuggestions.first)
        #expect(row.target == .snapshotPlaylist(local: local))
        #expect(row.catalogID == nil)
        #expect(row.itemKind == .playlist)
        #expect(row.handle == PlaylistHandle(local: local))
        #expect(row.entries.map(\.displayName) == ["One", "Two"])
        #expect(row.entries.map(\.position) == [0, 1])
    }

    @Test("A snapshot entry carries the lineage the player needs to queue it")
    func snapshotAncestry() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .snapshotPlaylist(local: UUID()), displayName: "Road Trip", at: Fix.t0
        )
        record.addSong(id: Fix.song, displayName: "One", ancestry: Fix.ancestry, at: Fix.t0)

        // Without this the song reaches `queuedVerdict` with no ancestors, comes
        // back `.unknown`, and the player refuses to queue it — every track in
        // the playlist losing its gapless join.
        let entry = try #require(kid.liveSuggestions.first?.entries.first)
        #expect(entry.ancestry.album == Fix.album)
        #expect(entry.ancestry.artist == Fix.artist)
    }

    @Test("A snapshot refuses anything that is not a song, and refuses duplicates")
    func snapshotRejects() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .snapshotPlaylist(local: UUID()), displayName: "Road Trip", at: Fix.t0
        )
        #expect(record.addSong(id: Fix.album, displayName: "An Album", at: Fix.t0) == nil)
        record.addSong(id: Fix.song, displayName: "One", at: Fix.t0)
        #expect(record.addSong(id: Fix.song, displayName: "One", at: Fix.t1) == nil)
        #expect(record.entries.count == 1)
    }

    @Test("A suggested catalog playlist carries its tracks too")
    func catalogPlaylistIsAlsoSnapshotted() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.catalogPlaylist), displayName: "Today's Hits", at: Fix.t0
        )
        record.addSong(id: Fix.song, displayName: "One", ancestry: Fix.ancestry, at: Fix.t0)

        // Nothing in this app puts a playlist into a track's lineage, so an
        // allow on the playlist identifier alone would open onto blocked rows.
        let row = try #require(kid.liveSuggestions.first)
        #expect(row.catalogID == Fix.catalogPlaylist)
        #expect(row.entries.count == 1)
    }
}

// MARK: - The policy fold

@Suite("Suggestions in the policy")
@MainActor
struct SuggestionPolicy {
    @Test("A live suggestion is folded in as an allow")
    func foldsAsAllow() throws {
        let (_, kid) = try newKid()
        kid.addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0)

        #expect(kid.buildPolicy().policy.entries == [.allow(Fix.album)])
    }

    @Test("A dismissed suggestion contributes no allow")
    func dismissedGrantsNothing() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0
        )
        kid.dismissSuggestion(record, at: Fix.t1)

        // The whole reason dismissal is not just a hidden tile: a kept allow
        // here would be an invisible one, listed on no screen in the app.
        #expect(kid.buildPolicy().policy.entries.isEmpty)
    }

    @Test("Re-suggesting a dismissed item brings its allow back")
    func restoreGrantsAgain() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0
        )
        kid.dismissSuggestion(record, at: Fix.t1)
        kid.restoreSuggestion(record, at: Fix.t2)

        #expect(kid.buildPolicy().policy.entries == [.allow(Fix.album)])
    }

    @Test("A snapshot playlist allows its songs and nothing of its own")
    func snapshotAllowsSongs() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .snapshotPlaylist(local: UUID()), displayName: "Road Trip", at: Fix.t0
        )
        record.addSong(id: Fix.song, displayName: "One", at: Fix.t0)
        record.addSong(id: Fix.song2, displayName: "Two", at: Fix.t0)

        #expect(kid.buildPolicy().policy.entries == [.allow(Fix.song), .allow(Fix.song2)])
    }

    @Test("A suggested catalog playlist allows itself and every track")
    func catalogPlaylistAllowsBoth() throws {
        let (_, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.catalogPlaylist), displayName: "Today's Hits", at: Fix.t0
        )
        record.addSong(id: Fix.song, displayName: "One", at: Fix.t0)

        #expect(
            kid.buildPolicy().policy.entries == [.allow(Fix.catalogPlaylist), .allow(Fix.song)]
        )
    }

    @Test(
        "A deny still beats a suggestion in every mode",
        arguments: [SandboxMode.allowOnly, .denyPlusAuto, .reportOnly]
    )
    func denyBeatsSuggestion(mode: SandboxMode) throws {
        let (_, kid) = try newKid(mode: mode)
        kid.addEntry(kind: .deny, id: Fix.artist, displayName: "An Artist", at: Fix.t0)
        kid.addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0)

        let engine = kid.makeEngine()
        let item = Item(id: Fix.album, rating: .clean, ancestors: [Ancestor(id: Fix.artist)])
        #expect(engine.evaluate(item) == .blocked(.deniedByParent(Fix.artist)))
    }

    @Test("An unreadable suggestion is dropped, never turned into a deny")
    func unreadableIsDropped() throws {
        let (context, kid) = try newKid()
        // A row this version cannot make sense of: no identifier, and not the
        // one kind that is allowed to lack one.
        let broken = SuggestionRecord(
            rawItemKind: ItemKind.album.rawValue,
            catalogID: nil,
            displayName: "Whatever",
            at: Fix.t0
        )
        context.insert(broken)
        kid.attach(broken, at: Fix.t0)

        let build = kid.buildPolicy()
        // The opposite of what an unreadable *policy* row does, and deliberately
        // so: a deny wins in every mode, so failing closed here would block
        // something nobody objected to.
        #expect(build.policy.entries.isEmpty)
        #expect(build.unreadableSuggestionIDs == [broken.id])
        #expect(build.hasUnreadableEntries == false)
    }

    @Test("An unreadable suggestion is reported apart from an unreadable entry")
    func namespacesStaySeparate() throws {
        let (context, kid) = try newKid()
        let brokenEntry = PolicyEntryRecord(
            rawKind: "nonsense",
            rawItemKind: ItemKind.album.rawValue,
            catalogID: Fix.album.rawValue,
            displayName: "An Album",
            at: Fix.t0
        )
        context.insert(brokenEntry)
        kid.attach(brokenEntry, at: Fix.t0)

        let broken = SuggestionRecord(
            rawItemKind: "nonsense", catalogID: "x", displayName: "Whatever", at: Fix.t0
        )
        context.insert(broken)
        kid.attach(broken, at: Fix.t0)

        let build = kid.buildPolicy()
        // The admin resolves `unreadableEntryIDs` against `kid.entries`. A
        // suggestion's id in there would look up to nothing.
        #expect(build.unreadableEntryIDs == [brokenEntry.id])
        #expect(build.unreadableSuggestionIDs == [broken.id])
    }

    @Test("A suggested album's explicit track is blocked at level 2 and plays at level 1")
    func theInversion() throws {
        let track = Item(
            id: Fix.explicitSong,
            rating: .explicit,
            ancestors: [Ancestor(id: Fix.album, rating: .clean)]
        )

        // Level 2: an allow on a *container* does not lift the rating check off
        // its children. Same rule that stops allowing an artist from permitting
        // their next explicit release, and a suggestion is not a way around it.
        let (_, two) = try newKid(mode: .denyPlusAuto)
        two.addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0)
        #expect(two.makeEngine().evaluate(track) == .blocked(.explicitContent))

        // Level 1: an allow-listed ancestor is enough and no rating is
        // consulted. So the most restrictive level permits what the middle one
        // refuses. Pinned here because the suggest sheet's playable count is
        // written against it.
        let (_, one) = try newKid(mode: .allowOnly)
        one.addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0)
        #expect(one.makeEngine().evaluate(track) == .allowed)
    }

    @Test("A suggestion reaches an allowOnly kid, which is the point of the feature")
    func reachesLevelOne() throws {
        let (_, kid) = try newKid(mode: .allowOnly)
        kid.addSuggestion(target: .catalog(Fix.artist), displayName: "An Artist", at: Fix.t0)

        let song = Item(
            id: Fix.song, rating: .clean, ancestors: [Ancestor(id: Fix.artist)]
        )
        #expect(kid.makeEngine().evaluate(song) == .allowed)
    }
}

// MARK: - Deletion

@Suite("Suggestions and deletion")
@MainActor
struct SuggestionDeletion {
    @Test("Clearing the logs leaves the parent's suggestions alone")
    func historySpares() throws {
        let (context, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0
        )
        kid.dismissSuggestion(record, at: Fix.t1)
        try context.save()

        kid.deleteHistory(at: Fix.t2)
        try context.save()

        #expect(kid.suggestions.count == 1)
        #expect(kid.dismissedSuggestions.count == 1)
    }

    @Test("Erasing everything the child did still leaves the parent's list")
    func everythingSpares() throws {
        let (context, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0
        )
        kid.dismissSuggestion(record, at: Fix.t1)
        try context.save()

        kid.deleteEverything(at: Fix.t2)
        try context.save()

        // Curation stays, the way the allow list does. And the dismissal stays
        // with it: clearing that flag would silently widen what the kid reaches,
        // which a delete must never do.
        #expect(kid.suggestions.count == 1)
        #expect(kid.dismissedSuggestions.count == 1)
        #expect(kid.buildPolicy().policy.entries.isEmpty)
    }

    @Test("Deleting a suggestion takes its snapshot entries with it")
    func cascade() throws {
        let (context, kid) = try newKid()
        let record = kid.addSuggestion(
            target: .snapshotPlaylist(local: UUID()), displayName: "Road Trip", at: Fix.t0
        )
        record.addSong(id: Fix.song, displayName: "One", at: Fix.t0)
        try context.save()

        kid.removeSuggestion(record, at: Fix.t1)
        try context.save()

        let entries = try context.fetch(FetchDescriptor<SuggestionEntryRecord>())
        #expect(entries.isEmpty)
    }
}

// MARK: - Origins

@Suite("Suggestion origins")
struct SuggestionOrigins {
    @Test("A suggestion origin survives the columns")
    func suggestionRoundTrips() throws {
        let origin = PlaybackOrigin.suggestion
        #expect(PlaybackOrigin(stored: origin.stored) == origin)
    }

    @Test("A suggested playlist origin survives the columns")
    func suggestedPlaylistRoundTrips() throws {
        let local = UUID()
        let origin = PlaybackOrigin.suggestedPlaylist(local)
        #expect(PlaybackOrigin(stored: origin.stored) == origin)
    }

    @Test("A suggested playlist is not read back as the kid's own")
    func notConfusedWithKidPlaylist() throws {
        let local = UUID()
        // Both carry a bare UUID in the same column. Only the frozen case name
        // tells them apart, and the report says different things about each.
        #expect(PlaybackOrigin.suggestedPlaylist(local).stored.name != PlaybackOrigin.kidPlaylist(local).stored.name)
        #expect(PlaybackOrigin(stored: PlaybackOrigin.kidPlaylist(local).stored) == .kidPlaylist(local))
    }

    @Test("A suggestion origin encodes and decodes through the one wire format")
    func codable() throws {
        let origins: [PlaybackOrigin] = [.suggestion, .suggestedPlaylist(UUID())]
        for origin in origins {
            let data = try JSONEncoder().encode(origin)
            #expect(try JSONDecoder().decode(PlaybackOrigin.self, from: data) == origin)
        }
    }

    @Test("The report describes a suggested playlist by name")
    func described() throws {
        let local = UUID()
        let description = PlaybackOrigin.suggestedPlaylist(local).described(
            kidPlaylistName: { _ in "The kid's own" },
            suggestionName: { _ in "Road Trip 2019" }
        )
        // Named from the suggestions table, not the kid's playlists — two
        // tables, two lookups, and a row in one is not a row in the other.
        #expect(description == .suggestedPlaylist(local, name: "Road Trip 2019"))
    }
}
