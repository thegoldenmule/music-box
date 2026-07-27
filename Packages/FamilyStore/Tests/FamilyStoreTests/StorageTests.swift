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
    static let playlist = CatalogID(.playlist, "playlist-A")

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_700_086_400)
}

@MainActor
private func newStore() throws -> ModelContext {
    ModelContext(try FamilyStore.inMemoryContainer())
}

@MainActor
private func insertKid(
    _ context: ModelContext,
    mode: SandboxMode = .denyPlusAuto,
    unrated: UnratedBehavior = .block
) -> Kid {
    let family = Family(at: Fix.t0)
    let kid = Kid(name: "Robin", mode: mode, unratedBehavior: unrated, at: Fix.t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.t0)
    return kid
}

// MARK: - Reading a policy back

@Suite("Building a policy from storage")
@MainActor
struct PolicyBuilding {
    @Test("Mode is read as stored, never defaulted", arguments: SandboxMode.allCases)
    func modeRoundTrips(mode: SandboxMode) throws {
        let context = try newStore()
        let kid = insertKid(context, mode: mode)
        #expect(kid.buildPolicy().policy.mode == mode)
    }

    @Test(
        "Unrated behavior is read as stored, never defaulted",
        arguments: UnratedBehavior.allCases
    )
    func unratedRoundTrips(behavior: UnratedBehavior) throws {
        let context = try newStore()
        let kid = insertKid(context, unrated: behavior)
        #expect(kid.buildPolicy().policy.unratedBehavior == behavior)
    }

    @Test("Entries become allow and deny in one list")
    func entriesRoundTrip() throws {
        let context = try newStore()
        let kid = insertKid(context)
        kid.addEntry(kind: .allow, id: Fix.album, displayName: "An Album")
        kid.addEntry(kind: .deny, id: Fix.artist, displayName: "A Band")

        let policy = kid.buildPolicy().policy
        #expect(policy.entries.count == 2)
        #expect(policy.entries.contains(.allow(Fix.album)))
        #expect(policy.entries.contains(.deny(Fix.artist)))
    }

    @Test("The engine built from storage enforces the stored deny")
    func engineHonorsStoredDeny() throws {
        let context = try newStore()
        let kid = insertKid(context)
        kid.addEntry(kind: .deny, id: Fix.artist, displayName: "A Band")

        let song = Item(id: Fix.song, rating: .clean, ancestors: [Ancestor(id: Fix.artist)])
        #expect(kid.makeEngine().evaluate(song) == .blocked(.deniedByParent(Fix.artist)))
    }

    @Test("A kind that does not read back becomes a deny, not a dropped rule")
    func unreadableKindFailsClosed() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = PolicyEntryRecord(
            rawKind: "permit",  // no such kind
            rawItemKind: ItemKind.artist.rawValue,
            catalogID: Fix.artist.rawValue,
            displayName: "A Band",
            at: Fix.t0
        )
        context.insert(record)
        kid.attach(record)

        let build = kid.buildPolicy()
        #expect(build.unreadableEntryIDs == [record.id])
        #expect(build.policy.entries == [.deny(Fix.artist)])
    }

    @Test("An item kind that does not read back is dropped and reported")
    func unreadableItemKindIsReported() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = PolicyEntryRecord(
            rawKind: PolicyEntry.Kind.deny.rawValue,
            rawItemKind: "station",  // MusicKit has these; the sandbox does not
            catalogID: "station-A",
            displayName: "A Station",
            at: Fix.t0
        )
        context.insert(record)
        kid.attach(record)

        let build = kid.buildPolicy()
        #expect(build.unreadableEntryIDs == [record.id])
        #expect(build.policy.entries.isEmpty)
    }

    @Test("A readable list reports nothing unreadable")
    func cleanListIsQuiet() throws {
        let context = try newStore()
        let kid = insertKid(context)
        kid.addEntry(kind: .allow, id: Fix.song, displayName: "A Song")
        #expect(kid.buildPolicy().hasUnreadableEntries == false)
    }
}

// MARK: - What entries carry

@Suite("Policy entries")
@MainActor
struct Entries {
    @Test("Display name and artwork URL are copied at add time")
    func metadataIsCopied() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let url = URL(string: "https://example.invalid/art.jpg")!
        let record = kid.addEntry(
            kind: .allow,
            id: Fix.album,
            displayName: "An Album",
            artworkURL: url
        )

        #expect(record.displayName == "An Album")
        #expect(record.artworkURL == url)
    }

    @Test("Adding an entry stamps the kid as modified")
    func addingStampsKid() throws {
        let context = try newStore()
        let kid = insertKid(context)
        kid.addEntry(kind: .allow, id: Fix.album, displayName: "An Album", at: Fix.t1)
        #expect(kid.modifiedAt == Fix.t1)
    }

    @Test("Removing an entry takes it off the policy")
    func removing() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = kid.addEntry(kind: .deny, id: Fix.artist, displayName: "A Band")
        kid.removeEntry(record, at: Fix.t1)

        #expect(kid.entries.isEmpty)
        #expect(kid.buildPolicy().policy.entries.isEmpty)
        #expect(kid.modifiedAt == Fix.t1)
    }
}

// MARK: - Mutation stamps

@Suite("modifiedAt")
@MainActor
struct ModifiedAt {
    @Test("Renaming stamps")
    func rename() throws {
        let context = try newStore()
        let kid = insertKid(context)
        kid.rename(to: "Sam", at: Fix.t1)
        #expect(kid.name == "Sam")
        #expect(kid.modifiedAt == Fix.t1)
    }

    @Test("Changing mode stamps")
    func mode() throws {
        let context = try newStore()
        let kid = insertKid(context, mode: .allowOnly)
        kid.setMode(.reportOnly, at: Fix.t1)
        #expect(kid.mode == .reportOnly)
        #expect(kid.modifiedAt == Fix.t1)
    }

    @Test("Changing unrated behavior stamps")
    func unrated() throws {
        let context = try newStore()
        let kid = insertKid(context)
        kid.setUnratedBehavior(.inheritFromAncestor, at: Fix.t1)
        #expect(kid.unratedBehavior == .inheritFromAncestor)
        #expect(kid.modifiedAt == Fix.t1)
    }

    @Test("Logging an event does not stamp the kid")
    func eventsDoNotStamp() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = SearchEventRecord(
            event: SearchEvent(
                term: "dinosaurs",
                at: Fix.t1,
                resultCount: 4,
                blockedCount: 1,
                gaveUpEarly: false
            )
        )
        context.insert(record)
        kid.attach(record)

        #expect(kid.modifiedAt == Fix.t0)
    }
}

// MARK: - Deletion

@Suite("Deletion")
@MainActor
struct Deletion {
    /// Builds a kid with one entry and one of each event, plus a summary.
    private func populated(_ context: ModelContext) -> Kid {
        let kid = insertKid(context)
        kid.addEntry(kind: .allow, id: Fix.album, displayName: "An Album")

        let search = SearchEventRecord(
            event: SearchEvent(
                term: "dinosaurs",
                at: Fix.t0,
                resultCount: 4,
                blockedCount: 1,
                gaveUpEarly: true
            )
        )
        let play = PlayEventRecord(
            event: PlayEvent(
                songID: Fix.song,
                albumID: Fix.album,
                artistID: Fix.artist,
                displayName: "A Song",
                at: Fix.t0,
                secondsPlayed: 90,
                origin: .search(term: "dinosaurs")
            )
        )
        let block = BlockEventRecord(
            event: BlockEvent(
                itemID: Fix.song,
                displayName: "A Rude Song",
                artistID: Fix.artist,
                at: Fix.t0,
                reason: .explicitContent,
                origin: .home
            )
        )
        let summary = WeeklySummaryRecord(weekStart: Fix.t0, payload: Data([0x01]))

        for record in [search as any PersistentModel, play, block, summary] {
            context.insert(record)
        }
        kid.attach(search)
        kid.attach(play)
        kid.attach(block)
        kid.attach(summary)
        return kid
    }

    @Test("Deleting history removes every event and every summary")
    func historyGoes() throws {
        let context = try newStore()
        let kid = populated(context)
        kid.deleteHistory(at: Fix.t1)

        #expect(kid.searches.isEmpty)
        #expect(kid.plays.isEmpty)
        #expect(kid.blocks.isEmpty)
        // A summary outliving its events is a record the parent asked us to
        // destroy.
        #expect(kid.summaries.isEmpty)
    }

    @Test("Deleting history leaves the lists and the mode alone")
    func curationSurvives() throws {
        let context = try newStore()
        let kid = populated(context)
        kid.setMode(.allowOnly, at: Fix.t0)
        kid.deleteHistory(at: Fix.t1)

        #expect(kid.entries.count == 1)
        #expect(kid.mode == .allowOnly)
        #expect(kid.buildPolicy().policy.entries == [.allow(Fix.album)])
    }

    @Test("Deleting a kid cascades to their entries and events")
    func cascade() throws {
        let context = try newStore()
        let kid = populated(context)
        context.delete(kid)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<PolicyEntryRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SearchEventRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PlayEventRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BlockEventRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WeeklySummaryRecord>()) == 0)
    }
}

// MARK: - Surviving a relaunch

@Suite("Relaunch")
@MainActor
struct Relaunch {
    /// The Stage 1 exit test: a kid, a list and a session's events are still
    /// there after the store is closed and reopened.
    ///
    /// The other half of that exit test — that records sit in a custom zone
    /// rather than the default one — cannot be checked here. There is no
    /// CloudKit container attached in v1, so there is no zone to inspect. See
    /// `FamilyStore.zoneNote`.
    @Test("A kid, a list and events survive closing and reopening the store")
    func survivesRelaunch() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        let kidID = UUID()

        do {
            let context = ModelContext(try FamilyStore.container(at: url))
            let family = Family(at: Fix.t0)
            let kid = Kid(
                id: kidID,
                name: "Robin",
                mode: .allowOnly,
                unratedBehavior: .inheritFromAncestor,
                at: Fix.t0
            )
            context.insert(family)
            context.insert(kid)
            family.addKid(kid, at: Fix.t0)
            kid.addEntry(kind: .allow, id: Fix.playlist, displayName: "Bedtime")

            let play = PlayEventRecord(
                event: PlayEvent(
                    songID: Fix.song,
                    displayName: "A Song",
                    at: Fix.t0,
                    secondsPlayed: 42,
                    origin: .playlist(Fix.playlist)
                )
            )
            context.insert(play)
            kid.attach(play)
            try context.save()
        }

        let context = ModelContext(try FamilyStore.container(at: url))
        var descriptor = FetchDescriptor<Kid>(predicate: #Predicate { $0.id == kidID })
        descriptor.fetchLimit = 1
        let kid = try #require(try context.fetch(descriptor).first)

        #expect(kid.name == "Robin")
        #expect(kid.mode == .allowOnly)
        #expect(kid.unratedBehavior == .inheritFromAncestor)
        #expect(kid.buildPolicy().policy.entries == [.allow(Fix.playlist)])
        #expect(kid.entries.first?.displayName == "Bedtime")

        let play = try #require(kid.plays.first?.event)
        #expect(play.songID == Fix.song)
        #expect(play.secondsPlayed == 42)
        #expect(play.origin == .playlist(Fix.playlist))
    }
}
