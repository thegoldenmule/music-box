import Foundation
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let artist = CatalogID(.artist, "artist-A")
    static let album = CatalogID(.album, "album-A")
    static let song = CatalogID(.song, "song-A")
    static let at = Date(timeIntervalSince1970: 1_700_000_000)
}

private func engine(
    _ mode: SandboxMode,
    _ entries: [PolicyEntry] = [],
    unrated: UnratedBehavior = .block
) -> PolicyEngine {
    PolicyEngine(policy: Policy(mode: mode, entries: entries, unratedBehavior: unrated))
}

private func knowledge(
    _ id: CatalogID = Fix.song,
    rating: ContentRating? = nil,
    ratingIsRecorded: Bool = true,
    ancestors: [Ancestor] = [],
    ancestryIsComplete: Bool = true
) -> ReviewAnnotator.Knowledge {
    ReviewAnnotator.Knowledge(
        item: Item(id: id, rating: rating, ancestors: ancestors),
        ancestryIsComplete: ancestryIsComplete,
        ratingIsRecorded: ratingIsRecorded
    )
}

// MARK: -

@Suite("Re-judging a stored row")
struct Annotating {
    @Test("The stored fact is carried through untouched")
    func factSurvives() {
        let annotated = ReviewAnnotator.annotate(
            "the fact",
            knowing: knowledge(rating: .clean),
            with: engine(.denyPlusAuto)
        )
        #expect(annotated.fact == "the fact")
        #expect(annotated.now == .allowed)
    }

    @Test("A song denied since it was played reads as blocked now")
    func denySinceThePlay() {
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(rating: .clean, ancestors: [Ancestor(id: Fix.artist)]),
            with: engine(.denyPlusAuto, [.deny(Fix.artist)])
        )
        #expect(annotated.now == .blocked(.deniedByParent(Fix.artist)))
        #expect(annotated.isAllowedNow == false)
    }
}

// MARK: -

@Suite("How far a verdict can be trusted")
struct Confidence {
    @Test("A deny that matched is exact, whatever else is missing")
    func denyIsFinal() {
        // Nothing we failed to resolve could unmake a rule that already fired.
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(
                ratingIsRecorded: false,
                ancestors: [Ancestor(id: Fix.artist)],
                ancestryIsComplete: false
            ),
            with: engine(.denyPlusAuto, [.deny(Fix.artist)])
        )
        #expect(annotated.confidence == .exact)
        #expect(annotated.now == .blocked(.deniedByParent(Fix.artist)))
    }

    @Test("Level 3 has nothing but denies to consult, so it is always exact")
    func reportOnlyIsExact() {
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(ratingIsRecorded: false, ancestryIsComplete: false),
            with: engine(.reportOnly)
        )
        #expect(annotated.confidence == .exact)
        #expect(annotated.now == .allowed)
    }

    @Test("Level 1 never consults a rating, so an absent one costs nothing")
    func allowOnlyIgnoresRating() {
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(ratingIsRecorded: false),
            with: engine(.allowOnly, [.allow(Fix.song)])
        )
        #expect(annotated.confidence == .exact)
        #expect(annotated.now == .allowed)
    }

    @Test("Level 1 blocked on partial lineage is provisional — a container might be listed")
    func allowOnlyBlockedIsProvisional() {
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(ratingIsRecorded: false, ancestryIsComplete: false),
            with: engine(.allowOnly)
        )
        #expect(annotated.confidence == .itemOnly)
        #expect(annotated.now == .blocked(.notOnAllowList))
    }

    /// The finding that made `rating` necessary — else every play reads blocked.
    @Test("Level 2 with no rating recorded offers no verdict at all")
    func unrecordedRatingIsUnknown() {
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(ratingIsRecorded: false),
            with: engine(.denyPlusAuto)
        )
        #expect(annotated.confidence == .unknown)
        #expect(annotated.now == nil)
        #expect(annotated.isAllowedNow == nil)
    }

    @Test("A recorded absence of a rating is a fact, and blocks exactly")
    func recordedUnratedIsExact() {
        // Catalog answered with no rating; `UnratedBehavior` decides, same way tomorrow.
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(rating: nil, ratingIsRecorded: true),
            with: engine(.denyPlusAuto)
        )
        #expect(annotated.confidence == .exact)
        #expect(annotated.now == .blocked(.unrated))
    }

    @Test("An artist carries no rating anywhere, so a missing one is irrelevant")
    func artistsNeedNoRating() {
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(Fix.artist, ratingIsRecorded: false),
            with: engine(.denyPlusAuto)
        )
        #expect(annotated.confidence == .exact)
        #expect(annotated.now == .allowed)
    }

    @Test("An item on the allow list skips the rating check, so it is exact")
    func perItemAllowIsExact() {
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(ratingIsRecorded: false),
            with: engine(.denyPlusAuto, [.allow(Fix.song)])
        )
        #expect(annotated.confidence == .exact)
        #expect(annotated.now == .allowed)
    }

    @Test("Allowed on partial lineage is provisional — an unseen container could be denied")
    func allowedOnPartialLineage() {
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(rating: .clean, ancestryIsComplete: false),
            with: engine(.denyPlusAuto)
        )
        #expect(annotated.confidence == .itemOnly)
        #expect(annotated.now == .allowed)
    }

    @Test("Blocked on a rating is exact — more lineage could only add reasons")
    func blockedOnRatingIsExact() {
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(rating: .explicit, ancestryIsComplete: false),
            with: engine(.denyPlusAuto)
        )
        #expect(annotated.confidence == .exact)
        #expect(annotated.now == .blocked(.explicitContent))
    }

    @Test("Inheriting from an ancestor we never resolved offers no verdict")
    func inheritNeedsLineage() {
        // The behavior reaches for ancestor ratings, and no row stores one.
        let annotated = ReviewAnnotator.annotate(
            0,
            knowing: knowledge(rating: nil, ancestryIsComplete: false),
            with: engine(.denyPlusAuto, unrated: .inheritFromAncestor)
        )
        #expect(annotated.confidence == .unknown)
        #expect(annotated.now == nil)
    }
}

// MARK: -

@Suite("What each kind of row knows about itself")
struct RowKnowledge {
    @Test("A play with both containers is complete")
    func playWithLineage() {
        let play = PlayEvent(
            songID: Fix.song,
            albumID: Fix.album,
            artistID: Fix.artist,
            displayName: "A Song",
            rating: .clean,
            at: Fix.at,
            secondsPlayed: 30,
            origin: .home
        )
        let knowledge = play.knowledge
        #expect(knowledge.ancestryIsComplete)
        #expect(knowledge.ratingIsRecorded)
        #expect(knowledge.item.rating == .clean)
        #expect(knowledge.item.ancestors.map(\.id) == [Fix.album, Fix.artist])
    }

    @Test("A play whose album never resolved is not complete")
    func playWithoutAlbum() {
        let play = PlayEvent(
            songID: Fix.song,
            artistID: Fix.artist,
            displayName: "A Song",
            rating: .clean,
            at: Fix.at,
            secondsPlayed: 30,
            origin: .home
        )
        #expect(!play.knowledge.ancestryIsComplete)
    }

    @Test("A song block is never complete — the album is not a column on it")
    func songBlockIsNeverComplete() {
        let block = BlockEvent(
            itemID: Fix.song,
            displayName: "A Song",
            artistID: Fix.artist,
            rating: .explicit,
            at: Fix.at,
            reach: .reached,
            reason: .explicitContent,
            origin: .home
        )
        #expect(!block.knowledge.ancestryIsComplete)
    }

    @Test("An artist block has no containers to miss")
    func artistBlockIsComplete() {
        let block = BlockEvent(
            itemID: Fix.artist,
            displayName: "A Band",
            at: Fix.at,
            reach: .reached,
            reason: .deniedByParent(Fix.artist),
            origin: .home
        )
        #expect(block.knowledge.ancestryIsComplete)
    }

    @Test("An unwritten rating reads back as unknown, not as unrated")
    func unknownIsNotUnrated() {
        let play = PlayEvent(
            songID: Fix.song,
            displayName: "A Song",
            at: Fix.at,
            secondsPlayed: 30,
            origin: .home
        )
        #expect(play.rating == .unknown)
        #expect(!play.knowledge.ratingIsRecorded)
        #expect(StoredRating(nil) == .unrated)
        #expect(StoredRating(nil).isRecorded)
    }
}
