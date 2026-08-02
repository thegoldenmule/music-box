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

    /// Removal is a **retraction**, not a delete: the row stays as the tombstone
    /// that lets the withdrawal reach another device, and `buildPolicy()` is
    /// what leaves it out of the policy. See `PolicyEntryRecord.retractedAt`.
    @Test("Removing an entry takes it off the policy and leaves the tombstone")
    func removing() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = kid.addEntry(kind: .deny, id: Fix.artist, displayName: "A Band", at: Fix.t0)
        kid.removeEntry(record, at: Fix.t1)

        #expect(kid.entries.count == 1)
        #expect(kid.liveEntries.isEmpty)
        #expect(record.isLive == false)
        #expect(kid.buildPolicy().policy.entries.isEmpty)
        #expect(kid.modifiedAt == Fix.t1)
    }

    /// Re-adding what was withdrawn lands on the same row rather than a second
    /// one. Two rows sharing a natural key is how a retraction gets lost: the
    /// screen shows one entry either way, and withdrawing it leaves the twin.
    @Test("Re-adding a withdrawn entry revives the row it withdrew")
    func reAddingRevives() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = kid.addEntry(kind: .deny, id: Fix.artist, displayName: "A Band", at: Fix.t0)
        kid.removeEntry(record, at: Fix.t1)

        let again = kid.addEntry(
            kind: .deny, id: Fix.artist, displayName: "A Band", at: Fix.t1 + 3600)

        #expect(again.id == record.id)
        #expect(kid.entries.count == 1)
        #expect(kid.buildPolicy().policy.entries.count == 1)
        // The sentence the admin shows a parent does not move.
        #expect(record.addedAt == Fix.t0)
    }
}

// MARK: -

@Suite("A withdrawal racing an assertion")
@MainActor
struct RetractionSkew {
    /// Two devices, two clocks, and no agreement about which came first. Taking
    /// the later timestamp is taking whichever device ran fast, so inside the
    /// window the answer is chosen by consequence instead: a **deny stands**.
    /// A phantom deny hides one item, visibly and fixably. A deny that loses a
    /// coin toss silently unblocks something a parent refused.
    @Test("Inside the skew window a deny stands")
    func denyStandsInsideWindow() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = kid.addEntry(kind: .deny, id: Fix.artist, displayName: "A Band", at: Fix.t0)

        record.retract(at: Fix.t0 + PolicyEntryRecord.clockSkewWindow / 2)

        #expect(record.isLive)
        #expect(kid.buildPolicy().policy.entries.count == 1)
    }

    @Test("Inside the skew window an allow does not")
    func allowFallsInsideWindow() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = kid.addEntry(kind: .allow, id: Fix.album, displayName: "An Album", at: Fix.t0)

        record.retract(at: Fix.t0 + PolicyEntryRecord.clockSkewWindow / 2)

        #expect(record.isLive == false)
        #expect(kid.buildPolicy().policy.entries.isEmpty)
    }

    /// Outside the window the clocks are trusted and the later fact wins,
    /// whichever kind it is.
    @Test("Outside the window the later fact wins, either way")
    func outsideWindowTimestampsDecide() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let beyond = PolicyEntryRecord.clockSkewWindow * 2

        let denied = kid.addEntry(kind: .deny, id: Fix.artist, displayName: "A Band", at: Fix.t0)
        denied.retract(at: Fix.t0 + beyond)
        #expect(denied.isLive == false)

        let allowed = kid.addEntry(kind: .allow, id: Fix.album, displayName: "An Album", at: Fix.t0)
        allowed.retract(at: Fix.t0 + beyond)
        allowed.reassert(at: Fix.t0 + beyond * 2)
        #expect(allowed.isLive)
    }

    /// A device that has not seen the retraction cannot resurrect the row just
    /// by holding an older copy — `reassert` leaves `retractedAt` in place so
    /// the comparison, not the absence, decides.
    @Test("Re-asserting keeps the retraction on the record")
    func reassertKeepsTheRetraction() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = kid.addEntry(kind: .allow, id: Fix.album, displayName: "An Album", at: Fix.t0)
        let beyond = PolicyEntryRecord.clockSkewWindow * 2

        record.retract(at: Fix.t0 + beyond)
        record.reassert(at: Fix.t0 + beyond * 2)

        #expect(record.retractedAt != nil)
        #expect(record.isLive)
    }

    /// The default for a row written before the column existed. `nil` means
    /// nothing was ever withdrawn, which is true of every one of them.
    @Test("A row that was never withdrawn is live")
    func neverWithdrawnIsLive() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let record = kid.addEntry(kind: .allow, id: Fix.album, displayName: "An Album", at: Fix.t0)

        #expect(record.retractedAt == nil)
        #expect(record.isLive)
    }
}

// MARK: -

@Suite("Two parents, one list, both offline")
@MainActor
struct OfflineListMerge {
    /// **The exit test the spec names**, at the level this store can express it:
    /// two parents edit the same list while offline, both reconnect, and neither
    /// one's work is lost. There is no list-shaped value anywhere — only
    /// independent rows carrying independent timestamps — so the result is the
    /// same whichever order the changes arrive in, and nothing has to arbitrate.
    @Test("Independent edits all survive, from either arrival order")
    func bothParentsEditsSurvive() throws {
        let beyond = PolicyEntryRecord.clockSkewWindow * 2

        // Parent A denies artist X and withdraws the allow on album Y.
        // Parent B allows album Z and withdraws the same allow on album Y.
        func applyA(_ kid: Kid, y: PolicyEntryRecord) {
            kid.addEntry(kind: .deny, id: Fix.artist, displayName: "X", at: Fix.t0 + beyond)
            kid.removeEntry(y, at: Fix.t0 + beyond)
        }
        func applyB(_ kid: Kid, y: PolicyEntryRecord) {
            kid.addEntry(kind: .allow, id: Fix.song, displayName: "Z", at: Fix.t0 + beyond)
            kid.removeEntry(y, at: Fix.t0 + beyond)
        }

        for order in [0, 1] {
            let context = try newStore()
            let kid = insertKid(context, mode: .denyPlusAuto)
            let y = kid.addEntry(kind: .allow, id: Fix.album, displayName: "Y", at: Fix.t0)

            if order == 0 {
                applyA(kid, y: y)
                applyB(kid, y: y)
            } else {
                applyB(kid, y: y)
                applyA(kid, y: y)
            }

            let entries = kid.buildPolicy().policy.entries
            #expect(entries.contains(.deny(Fix.artist)))
            #expect(entries.contains(.allow(Fix.song)))
            // Withdrawn by both. Doing it twice is doing it once.
            #expect(entries.contains(.allow(Fix.album)) == false)
            #expect(entries.count == 2)
        }
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

    /// The loudest writer in the store, on the record sync most needs quiet.
    /// Hearting a twenty-five-album artist ran this once per album, and every
    /// one of those stamps made a child listening to music look like a parent
    /// editing settings. It stamped before the fix.
    @Test("Filling the library index does not stamp the kid")
    func libraryIndexDoesNotStamp() throws {
        let context = try newStore()
        let kid = insertKid(context)

        kid.appendIndex(
            from: Fix.artist,
            with: [
                LibraryIndexRow(
                    catalogID: Fix.song,
                    displayName: "A Song",
                    source: Fix.artist
                )
            ],
            at: Fix.t1
        )

        #expect(kid.libraryIndex.count == 1)
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
                reach: .unseen,
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

    /// The assertion above passes on a `removeAll()` that only detaches, which
    /// is what this used to do: the rows stayed on disk with a null kid, and
    /// because every query is `kid?.id == kidID` they were invisible to the
    /// report. A parent would have seen exactly what they expected while the
    /// data sat there. Check the store, not the relationship.
    @Test("Deleting history takes the rows off disk, not just off the kid")
    func historyLeavesNoOrphans() throws {
        let context = try newStore()
        let kid = populated(context)
        kid.deleteHistory(at: Fix.t1)
        try context.save()

        let searches = try context.fetch(FetchDescriptor<SearchEventRecord>())
        let plays = try context.fetch(FetchDescriptor<PlayEventRecord>())
        let blocks = try context.fetch(FetchDescriptor<BlockEventRecord>())
        let summaries = try context.fetch(FetchDescriptor<WeeklySummaryRecord>())

        #expect(searches.isEmpty)
        #expect(plays.isEmpty)
        #expect(blocks.isEmpty)
        #expect(summaries.isEmpty)
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
