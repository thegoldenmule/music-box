import Foundation
import Testing

@testable import FamilyStore

@testable import FamilySync

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0 + seconds }

private func entry(
    name: String = "n",
    kind: String = "deny",
    added: Date = t0,
    asserted: Date = .distantPast,
    retracted: Date? = nil,
    displayName: String = "A Band",
    touched: Date
) -> SyncedRecord {
    var fields: [String: SyncValue] = [
        Field.id: .uuid(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!),
        "kind": .string(kind),
        Field.displayName: .string(displayName),
        Field.addedAt: .date(added),
        Field.assertedAt: .date(asserted),
        Field.modifiedAt: .date(touched),
    ]
    fields[Field.retractedAt] = retracted.map { .date($0) }
    return SyncedRecord(name: name, type: "PolicyEntryRecord", fields: fields)
}

private func merged(_ a: SyncedRecord, _ b: SyncedRecord) -> SyncedRecord {
    Merge.resolve(local: a, remote: b, rules: Merge.rules(for: a.type)).record
}

// MARK: -

@Suite("Merging two versions of one record")
struct MergingRecords {
    /// **The property the whole design rests on.** Every rule is a function of
    /// the two values and nothing else — no bias toward local, no "whoever
    /// arrived second" — so a device that syncs A-then-B lands where one that
    /// syncs B-then-A does. Without this the offline exit test is unanswerable,
    /// because two parents reconnecting in either order is the whole scenario.
    @Test("Merging is commutative")
    func commutative() {
        let a = entry(asserted: at(500), touched: at(500))
        let b = entry(retracted: at(900), touched: at(900))

        #expect(merged(a, b).fields == merged(b, a).fields)
    }

    @Test("Merging is idempotent")
    func idempotent() {
        let a = entry(asserted: at(500), touched: at(500))
        let b = entry(retracted: at(900), touched: at(900))
        let once = merged(a, b)

        #expect(merged(once, b).fields == once.fields)
        #expect(merged(once, once).fields == once.fields)
    }

    /// Both timestamps only ever move forward, so each one's maximum is the
    /// later fact and `isLive` in the store decides the rest. Nothing here has
    /// to know what "live" means — which is why a withdrawal and a re-assert
    /// cannot cancel each other out.
    @Test("Assertion and retraction each take the later of the two")
    func monotonicTimestamps() {
        let withdrawn = entry(retracted: at(900), touched: at(900))
        let reasserted = entry(asserted: at(1500), touched: at(1500))

        let result = merged(withdrawn, reasserted)
        #expect(result.date(Field.assertedAt) == at(1500))
        #expect(result.date(Field.retractedAt) == at(900))
    }

    /// A device that has not seen the retraction holds a copy with no
    /// `retractedAt` at all. Absence must not read as "withdraw it", and it must
    /// not read as "un-withdraw it" either.
    @Test("A side that never saw the retraction does not undo it")
    func absenceIsNotAVote() {
        let withdrawn = entry(retracted: at(900), touched: at(900))
        let stale = entry(touched: at(100))

        #expect(merged(withdrawn, stale).date(Field.retractedAt) == at(900))
        #expect(merged(stale, withdrawn).date(Field.retractedAt) == at(900))
    }

    /// `addedAt` is what the admin shows a parent — *"you added this on
    /// Tuesday"* — and a re-add on another device must not rewrite that
    /// sentence.
    @Test("The moment something began takes the earlier of the two")
    func earliestWins() {
        let first = entry(added: at(100), touched: at(100))
        let laterCopy = entry(added: at(9000), touched: at(9000))

        #expect(merged(first, laterCopy).date(Field.addedAt) == at(100))
    }

    /// The one rule that can lose an edit, restricted to fields the app is
    /// willing to lose one of.
    @Test("A cosmetic field follows whichever record was touched last")
    func cosmeticFollowsTheNewerRecord() {
        let mine = entry(displayName: "Old Name", touched: at(100))
        let theirs = entry(displayName: "New Name", touched: at(900))

        #expect(merged(mine, theirs).string(Field.displayName) == "New Name")
        #expect(merged(theirs, mine).string(Field.displayName) == "New Name")
    }

    /// Two records sharing a natural key but disagreeing on something that never
    /// changes are not the same thing. Reported rather than resolved: it means
    /// the key is too loose or something is wrong, and both are worth knowing
    /// before they are a support question.
    @Test("An immutable field that disagrees is reported, not silently picked")
    func immutableDisagreementIsReported() {
        var mine = entry(touched: at(100))
        var theirs = entry(touched: at(900))
        mine[Field.id] = .uuid(UUID())
        theirs[Field.id] = .uuid(UUID())

        let outcome = Merge.resolve(
            local: mine, remote: theirs, rules: Merge.rules(for: "PolicyEntryRecord"))
        #expect(outcome.conflicts == [Field.id])
        // And the local value is kept rather than a coin toss.
        #expect(outcome.record.fields[Field.id] == mine.fields[Field.id])
    }

    @Test("The merged record is at least as new as either side")
    func modifiedAtAdvances() {
        let result = merged(entry(touched: at(100)), entry(touched: at(900)))
        #expect(result.date(Field.modifiedAt) == at(900))
    }
}

// MARK: -

@Suite("Two parents, one list, both offline")
struct OfflineExitTest {
    /// **The exit test the spec names**, at the layer that decides it.
    ///
    /// Parent A denies artist X and withdraws the allow on album Y. Parent B
    /// allows album Z and withdraws the same allow on Y. Both reconnect. Every
    /// intended change survives, the double withdrawal is idempotent, and the
    /// result is identical from either arrival order.
    ///
    /// It passes for a structural reason rather than a clever one: **nothing is
    /// co-written.** Four independent rows carrying independent timestamps, so
    /// there is no list-shaped value for last-write-wins to destroy.
    @Test("Neither parent's edits are lost, from either arrival order")
    func neitherParentLosesWork() {
        // Y, as each parent left it: both withdrew it, at slightly different
        // moments by their own clocks.
        let yFromA = entry(name: "Y", kind: "allow", retracted: at(600), touched: at(600))
        let yFromB = entry(name: "Y", kind: "allow", retracted: at(640), touched: at(640))

        // X and Z were each created on one device and never touched on the
        // other, so they arrive whole.
        let x = entry(name: "X", kind: "deny", added: at(600), touched: at(600))
        let z = entry(name: "Z", kind: "allow", added: at(640), touched: at(640))

        let forward = [merged(yFromA, yFromB), x, z]
        let backward = [merged(yFromB, yFromA), x, z]

        #expect(forward.map(\.fields) == backward.map(\.fields))

        // Y is withdrawn, and withdrawing it twice is withdrawing it once.
        #expect(forward[0].date(Field.retractedAt) == at(640))
        // X and Z both survive.
        #expect(forward[1].string("kind") == "deny")
        #expect(forward[2].string("kind") == "allow")
    }
}

// MARK: -

@Suite("Rules that must exist")
struct RuleCoverage {
    /// The default rule is the only one that can lose an edit, so what matters
    /// is not that these entries are right but that nothing safety-critical is
    /// *missing* from them. A field that decides what a child can reach and is
    /// absent here silently falls to whichever record was touched last.
    @Test("Every safety-critical field has an explicit rule")
    func safetyCriticalFieldsAreNamed() {
        let policy = Merge.rules(for: "PolicyEntryRecord")
        #expect(policy[Field.assertedAt] == .latest)
        #expect(policy[Field.retractedAt] == .latest)
        #expect(policy[Field.addedAt] == .earliest)

        let suggestion = Merge.rules(for: "SuggestionRecord")
        #expect(suggestion[Field.dismissedAt] == .latest)
        #expect(suggestion[Field.restoredAt] == .latest)

        let device = Merge.rules(for: "DeviceRecord")
        #expect(device[Field.revokedAt] == .sticky)

        // A decision row *is* one decision, so two copies are identical and
        // there is nothing to reconcile. Which one is in force is resolved
        // across rows in FamilyStore, narrowest-wins.
        #expect(Merge.rules(for: "SandboxSettingRecord")[Field.decidedAt] == .immutable)
    }

    /// Revocation is a tombstone. A device that has not heard about it holds a
    /// copy with `revokedAt` absent, and that must not un-revoke it — which is
    /// the same failure a delete would have had, one level up.
    @Test("A revocation survives a device that has not heard about it")
    func revocationIsSticky() {
        let revoked = SyncedRecord(
            name: "d", type: "DeviceRecord",
            fields: [Field.revokedAt: .date(at(900)), Field.modifiedAt: .date(at(900))])
        let unaware = SyncedRecord(
            name: "d", type: "DeviceRecord", fields: [Field.modifiedAt: .date(at(2000))])

        #expect(merged(revoked, unaware).date(Field.revokedAt) == at(900))
        // Even though the unaware copy is the newer record.
        #expect(merged(unaware, revoked).date(Field.revokedAt) == at(900))
    }
}

// MARK: -

@Suite("When two clocks disagree")
struct ClockSkew {
    /// **The only place in the system that guesses**, and it is here rather than
    /// on the record because this is the only place two device clocks meet. It
    /// started out at read time and that was wrong: on one device the order of
    /// two actions is not in doubt, and failing closed there made a parent's own
    /// edit appear not to work for two minutes.
    ///
    /// A deny stands. A phantom deny hides one item a parent meant to allow, on
    /// the screen they are already looking at. A deny that loses a coin toss
    /// silently un-blocks something a parent explicitly refused.
    @Test("Inside the window a deny stands")
    func denyStands() {
        let asserted = entry(kind: "deny", added: at(600), touched: at(600))
        let withdrawn = entry(kind: "deny", added: at(600), retracted: at(640), touched: at(640))

        let result = merged(asserted, withdrawn)
        let assertion = try! #require(result.date(Field.assertedAt))
        let retraction = try! #require(result.date(Field.retractedAt))
        #expect(assertion > retraction)
    }

    @Test("Inside the window an allow does not")
    func allowFalls() {
        let asserted = entry(kind: "allow", added: at(600), touched: at(600))
        let withdrawn = entry(kind: "allow", added: at(600), retracted: at(640), touched: at(640))

        let result = merged(asserted, withdrawn)
        let assertion = try! #require(result.date(Field.assertedAt))
        let retraction = try! #require(result.date(Field.retractedAt))
        #expect(retraction > assertion)
    }

    /// Outside the window the clocks are trusted and the later fact wins,
    /// whichever kind it is. The bias is a tiebreak, not a thumb on the scale.
    @Test("Outside the window the later fact wins, either way")
    func outsideTheWindowTimestampsDecide() {
        let beyond = Merge.clockSkewWindow * 2
        let withdrawn = entry(kind: "deny", added: at(600), retracted: at(600 + beyond), touched: at(900))

        let result = merged(withdrawn, withdrawn)
        let assertion = try! #require(result.date(Field.assertedAt))
        let retraction = try! #require(result.date(Field.retractedAt))
        #expect(retraction > assertion)
    }

    /// The bias is a nudge to a timestamp rather than a flag, so the outcome is
    /// still a plain pair of dates any build can compare — and still the same
    /// from either arrival order, which a flag written by whichever side merged
    /// first would not be.
    @Test("The tiebreak is still commutative")
    func biasIsCommutative() {
        let a = entry(kind: "deny", added: at(600), touched: at(600))
        let b = entry(kind: "deny", added: at(600), retracted: at(640), touched: at(640))

        #expect(merged(a, b).fields == merged(b, a).fields)
    }

    /// A row that has only ever been added once carries `.distantPast` in
    /// `assertedAt`, so comparing *that* against a retraction would put every
    /// such row far outside the window and skip the rule entirely. The effective
    /// assertion reads through to `addedAt`, exactly as the store does.
    @Test("A row that was never re-asserted still gets the rule")
    func distantPastReadsThroughToAddedAt() {
        let never = entry(kind: "deny", added: at(600), asserted: .distantPast, touched: at(600))
        let withdrawn = entry(
            kind: "deny", added: at(600), asserted: .distantPast, retracted: at(640),
            touched: at(640))

        let result = merged(never, withdrawn)
        let assertion = try! #require(result.date(Field.assertedAt))
        #expect(assertion > at(640))
    }

    /// Same asymmetry, same reason: a dismissal withdraws an allow.
    @Test("Inside the window a dismissal stands over a restore")
    func dismissalStands() {
        func suggestion(dismissed: Date?, restored: Date?, touched: Date) -> SyncedRecord {
            var fields: [String: SyncValue] = [Field.modifiedAt: .date(touched)]
            fields[Field.dismissedAt] = dismissed.map { .date($0) }
            fields[Field.restoredAt] = restored.map { .date($0) }
            return SyncedRecord(name: "s", type: "SuggestionRecord", fields: fields)
        }

        let passed = suggestion(dismissed: at(600), restored: nil, touched: at(600))
        let reoffered = suggestion(dismissed: at(600), restored: at(640), touched: at(640))

        let result = merged(passed, reoffered)
        let dismissed = try! #require(result.date(Field.dismissedAt))
        let restored = try! #require(result.date(Field.restoredAt))
        #expect(dismissed > restored)
    }
}
