import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

private enum Fix {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// Comfortably outside the skew window, so the clocks are trusted.
    static let beyond = PolicyEntryRecord.clockSkewWindow * 2
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
    let kid = Kid(name: "Ada", mode: mode, unratedBehavior: unrated, at: Fix.t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: Fix.t0)
    return kid
}

// MARK: -

@Suite("Which sandbox setting is in force")
@MainActor
struct SandboxSettings {
    /// No decisions is the column's own set value, not a substituted default.
    @Test("With no decisions the stored column is the answer")
    func fallsBackToTheColumn() throws {
        let context = try newStore()
        let kid = insertKid(context, mode: .allowOnly, unrated: .inheritFromAncestor)

        #expect(kid.sandboxSettings.isEmpty)
        #expect(kid.effectiveMode == .allowOnly)
        #expect(kid.effectiveUnratedBehavior == .inheritFromAncestor)
        #expect(kid.buildPolicy().policy.mode == .allowOnly)
    }

    @Test("A decision beats the column, and the column follows along")
    func decisionWins() throws {
        let context = try newStore()
        let kid = insertKid(context, mode: .reportOnly)

        kid.setMode(.allowOnly, at: Fix.t0 + Fix.beyond)

        #expect(kid.effectiveMode == .allowOnly)
        // Cache refreshed too — an older build reading the column agrees.
        #expect(kid.mode == .allowOnly)
        #expect(kid.sandboxSettings.count == 1)
    }

    @Test("The most recent decision is the one in force")
    func latestWins() throws {
        let context = try newStore()
        let kid = insertKid(context)

        kid.setMode(.reportOnly, at: Fix.t0 + Fix.beyond)
        kid.setMode(.denyPlusAuto, at: Fix.t0 + Fix.beyond * 2)

        #expect(kid.effectiveMode == .denyPlusAuto)
        // Append-only — a rewrite would erase who set what, and when.
        #expect(kid.sandboxSettings.count == 2)
    }

    /// Wrong toward narrow is visible and fixable; wrong toward wide is silent.
    @Test("Concurrent decisions resolve to the narrower one")
    func concurrentResolvesNarrower() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let half = PolicyEntryRecord.clockSkewWindow / 2

        // Dad widens; Mum tightens a moment later by her device's clock.
        kid.setMode(.reportOnly, at: Fix.t0 + Fix.beyond)
        kid.setMode(.allowOnly, at: Fix.t0 + Fix.beyond + half)

        #expect(kid.effectiveMode == .allowOnly)
    }

    /// The tightening need not be the later of the two to survive.
    @Test("Narrower wins whichever order it arrived in")
    func narrowerWinsEitherOrder() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let half = PolicyEntryRecord.clockSkewWindow / 2

        kid.setMode(.allowOnly, at: Fix.t0 + Fix.beyond)
        kid.setMode(.reportOnly, at: Fix.t0 + Fix.beyond + half)

        #expect(kid.effectiveMode == .allowOnly)
    }

    @Test("Outside the window a genuine later decision stands, even a wider one")
    func laterDecisionStandsOutsideWindow() throws {
        let context = try newStore()
        let kid = insertKid(context)

        kid.setMode(.allowOnly, at: Fix.t0 + Fix.beyond)
        kid.setMode(.reportOnly, at: Fix.t0 + Fix.beyond * 3)

        // A parent widening their child's sandbox an hour later meant it.
        #expect(kid.effectiveMode == .reportOnly)
    }

    @Test("Unrated behavior resolves the same way, with block as the narrowest")
    func unratedNarrows() throws {
        let context = try newStore()
        let kid = insertKid(context, unrated: .allow)
        let half = PolicyEntryRecord.clockSkewWindow / 2

        kid.setUnratedBehavior(.allow, at: Fix.t0 + Fix.beyond)
        kid.setUnratedBehavior(.block, at: Fix.t0 + Fix.beyond + half)

        #expect(kid.effectiveUnratedBehavior == .block)
    }

    /// Unreadable is skipped, not counted — guessing would fake a default.
    @Test("A decision this build cannot read is not a vote")
    func unreadableIsSkipped() throws {
        let context = try newStore()
        let kid = insertKid(context, mode: .denyPlusAuto)

        let future = SandboxSettingRecord(
            key: .mode,
            rawValue: "someLevelFromTheFuture",
            at: Fix.t0 + Fix.beyond * 10
        )
        context.insert(future)
        kid.attach(future)

        #expect(kid.effectiveMode == .denyPlusAuto)
    }

    @Test("An unreadable decision does not suppress a readable one")
    func unreadableDoesNotMaskReadable() throws {
        let context = try newStore()
        let kid = insertKid(context, mode: .reportOnly)

        kid.setMode(.allowOnly, at: Fix.t0 + Fix.beyond)
        let future = SandboxSettingRecord(
            key: .mode,
            rawValue: "someLevelFromTheFuture",
            at: Fix.t0 + Fix.beyond * 10
        )
        context.insert(future)
        kid.attach(future)

        #expect(kid.effectiveMode == .allowOnly)
    }

    /// A whole-record merge on `Kid` drops the tightening about half the time.
    @Test("A rename cannot contend with a sandbox decision")
    func renameCannotSwallowATightening() throws {
        let context = try newStore()
        let kid = insertKid(context, mode: .reportOnly)

        kid.setMode(.allowOnly, at: Fix.t0 + Fix.beyond)
        kid.rename(to: "Ada B", at: Fix.t0 + Fix.beyond * 2)

        // The rename changes nothing reachable — the decision lives elsewhere.
        #expect(kid.name == "Ada B")
        #expect(kid.effectiveMode == .allowOnly)
    }

    @Test("Decisions go with the kid")
    func decisionsCascade() throws {
        let context = try newStore()
        let kid = insertKid(context)
        kid.setMode(.allowOnly, at: Fix.t0 + Fix.beyond)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<SandboxSettingRecord>()).count == 1)

        context.delete(kid)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<SandboxSettingRecord>()).isEmpty)
    }
}

// MARK: -

@Suite("Whether Now Playing shows a related shelf")
@MainActor
struct RelatedInNowPlaying {
    /// The one setting with no column behind it, so the default is the literal.
    @Test("Nobody has decided, so it is off")
    func defaultsToOff() throws {
        let context = try newStore()
        let kid = insertKid(context)

        #expect(kid.sandboxSettings.isEmpty)
        #expect(kid.effectiveRelatedInNowPlaying == false)
    }

    @Test("A decision turns it on, and a later one turns it back off")
    func decisionWins() throws {
        let context = try newStore()
        let kid = insertKid(context)

        kid.setRelatedInNowPlaying(true, at: Fix.t0 + Fix.beyond)
        #expect(kid.effectiveRelatedInNowPlaying)

        kid.setRelatedInNowPlaying(false, at: Fix.t0 + Fix.beyond * 2)
        #expect(kid.effectiveRelatedInNowPlaying == false)
        // Append-only, like every other decision.
        #expect(kid.sandboxSettings.count == 2)
    }

    /// The asymmetry that matters when two parents disagree inside the window.
    @Test("Concurrent decisions resolve to off")
    func concurrentResolvesOff() throws {
        let context = try newStore()
        let kid = insertKid(context)
        let half = PolicyEntryRecord.clockSkewWindow / 2

        // Whichever order the clocks report, the no is what stands.
        kid.setRelatedInNowPlaying(false, at: Fix.t0 + Fix.beyond)
        kid.setRelatedInNowPlaying(true, at: Fix.t0 + Fix.beyond + half)

        #expect(kid.effectiveRelatedInNowPlaying == false)
    }

    /// A future build's value must read back as unrecognised, never as a yes.
    @Test("An unparseable value is not a decision")
    func garbageIsNotAVote() throws {
        let context = try newStore()
        let kid = insertKid(context)

        kid.setRelatedInNowPlaying(true, at: Fix.t0 + Fix.beyond)
        let record = SandboxSettingRecord(
            key: .relatedInNowPlaying,
            rawValue: "sometimes",
            at: Fix.t0 + Fix.beyond * 2
        )
        context.insert(record)
        kid.attach(record)

        // The newest row parses to nothing, so the last real decision stands.
        #expect(kid.effectiveRelatedInNowPlaying)
    }
}
