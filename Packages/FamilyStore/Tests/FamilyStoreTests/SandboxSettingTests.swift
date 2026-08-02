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
    /// The state every existing store is in: no decisions, because the table did
    /// not exist. The column is not a *default* here — it is the value a parent
    /// actually set — so the spec's rule that no default is substituted at
    /// evaluation time still holds.
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
        // The cache is refreshed too, so an older build reading the column
        // directly sees the same answer rather than a stale one.
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
        // Append-only: changing your mind writes another row, so the admin can
        // show who set what and when.
        #expect(kid.sandboxSettings.count == 2)
    }

    /// **The failure this whole record exists to prevent.** Two parents deciding
    /// within the skew window is two clocks that do not agree what "after"
    /// means, so taking the later timestamp is taking whichever device ran fast.
    /// Getting it wrong toward narrow shows a stricter sandbox than someone
    /// picked — visible, one tap to fix. Getting it wrong toward wide hands a
    /// child reach nobody agreed to, silently.
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

    /// And the same the other way round: the tightening does not have to be the
    /// later of the two to survive.
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

    /// A value written by a newer build. Guessing what it meant is how a newer
    /// build's tightening becomes an older build's default, so it is skipped
    /// rather than counted — and if it is the only decision, the column answers.
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

    /// The reason these two fields left `Kid` at all: on one record with `name`,
    /// a whole-record merge puts a rename and a tightening in contention, and
    /// roughly half the time the tightening is the one that disappears.
    @Test("A rename cannot contend with a sandbox decision")
    func renameCannotSwallowATightening() throws {
        let context = try newStore()
        let kid = insertKid(context, mode: .reportOnly)

        kid.setMode(.allowOnly, at: Fix.t0 + Fix.beyond)
        kid.rename(to: "Ada B", at: Fix.t0 + Fix.beyond * 2)

        // The rename is the later write to `Kid`, and it changes nothing about
        // what she can reach, because the decision does not live there.
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
