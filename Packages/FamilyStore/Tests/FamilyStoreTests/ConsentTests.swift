import Foundation
import Testing

@testable import FamilyStore

private enum Who {
    static let robin = UUID()
    static let sam = UUID()
    static let stranger = UUID()

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
}

private func agreed(_ scope: ConsentScope, _ kids: UUID...) -> RecordedConsent {
    RecordedConsent(scope: scope, kidIDs: Set(kids))
}

// MARK: -

@Suite("What an invitation exposes")
struct WhatIsExposed {
    /// There is no per-adult scoping anywhere in this design: a participant holds
    /// the household zone and both zones of every child.
    @Test("Sharing the household exposes every child in it")
    func householdIsEverybody() {
        let exposed = Consent.kidsExposed(
            by: .shareHousehold, householdKids: [Who.robin, Who.sam])
        #expect(exposed == [Who.robin, Who.sam])
    }

    @Test("A child's own account exposes only that child")
    func childIsOne() {
        let exposed = Consent.kidsExposed(
            by: .childAccountParticipates,
            householdKids: [Who.robin, Who.sam],
            subject: Who.robin
        )
        #expect(exposed == [Who.robin])
    }

    /// `SharePlan.grants` returns nothing for a kid outside the household, so there
    /// is no invitation to consent to.
    @Test("A child who is not in this household is exposed by nothing")
    func strangerIsNothing() {
        let exposed = Consent.kidsExposed(
            by: .childAccountParticipates,
            householdKids: [Who.robin],
            subject: Who.stranger
        )
        #expect(exposed.isEmpty)
    }

    @Test("A child invitation with nobody named exposes nothing")
    func noSubjectIsNothing() {
        let exposed = Consent.kidsExposed(
            by: .childAccountParticipates, householdKids: [Who.robin], subject: nil)
        #expect(exposed.isEmpty)
    }
}

// MARK: -

@Suite("Whether consent covers it")
struct WhetherCovered {
    @Test("Nothing recorded covers nothing")
    func emptyLedger() {
        #expect(
            !Consent.isGiven(
                scope: .shareHousehold, householdKids: [Who.robin], recorded: []))
    }

    @Test("An agreement naming the child covers it")
    func straightforward() {
        #expect(
            Consent.isGiven(
                scope: .shareHousehold,
                householdKids: [Who.robin],
                recorded: [agreed(.shareHousehold, Who.robin)]
            ))
    }

    /// **The case this type exists for.** A screen that remembered "they already
    /// agreed" would hand out a second child's search history on the strength of an
    /// agreement about their sibling.
    @Test("A child added after the agreement is not covered by it")
    func newKidReopensTheQuestion() {
        let recorded = [agreed(.shareHousehold, Who.robin)]

        #expect(
            Consent.isGiven(
                scope: .shareHousehold, householdKids: [Who.robin], recorded: recorded))
        #expect(
            !Consent.isGiven(
                scope: .shareHousehold,
                householdKids: [Who.robin, Who.sam],
                recorded: recorded
            ))
        #expect(
            Consent.kidsNotCovered(
                scope: .shareHousehold,
                householdKids: [Who.robin, Who.sam],
                recorded: recorded
            ) == [Who.sam])
    }

    @Test("Agreements accumulate across separate sittings")
    func unionOfRows() {
        let recorded = [agreed(.shareHousehold, Who.robin), agreed(.shareHousehold, Who.sam)]
        #expect(
            Consent.isGiven(
                scope: .shareHousehold,
                householdKids: [Who.robin, Who.sam],
                recorded: recorded
            ))
    }

    /// Two different asks, and the child-account one is the larger — it makes a
    /// minor's own Apple Account a share participant.
    @Test("Consent for one scope is never consent for the other")
    func scopesDoNotSubstitute() {
        let household = [agreed(.shareHousehold, Who.robin)]
        #expect(
            !Consent.isGiven(
                scope: .childAccountParticipates,
                householdKids: [Who.robin],
                subject: Who.robin,
                recorded: household
            ))

        let child = [agreed(.childAccountParticipates, Who.robin)]
        #expect(
            !Consent.isGiven(
                scope: .shareHousehold, householdKids: [Who.robin], recorded: child))
    }

    /// Falls out of the set arithmetic rather than being a special case: no child
    /// data exists to agree about, and the next invitation after a child is added
    /// asks.
    @Test("A household with no children needs no agreement")
    func noKidsNeedsNothing() {
        #expect(Consent.isGiven(scope: .shareHousehold, householdKids: [], recorded: []))
    }

    @Test("A leftover agreement about a departed child covers nobody present")
    func staleRowDoesNotHelp() {
        #expect(
            !Consent.isGiven(
                scope: .shareHousehold,
                householdKids: [Who.sam],
                recorded: [agreed(.shareHousehold, Who.robin)]
            ))
    }
}

// MARK: -

@Suite("Reading a stored agreement")
@MainActor
struct ReadingARow {
    @Test("A row reads back as what was agreed")
    func roundTrips() {
        let row = ConsentRecord(
            scope: .shareHousehold, kidIDs: [Who.robin, Who.sam], appVersion: "1.0 (3)",
            at: Who.t0)
        #expect(row.recorded == agreed(.shareHousehold, Who.robin, Who.sam))
        #expect(row.agreedAt == Who.t0)
        #expect(row.appVersion == "1.0 (3)")
    }

    /// `ConsentRecord.recorded` also guards an unreadable `scopeRaw`, and there is
    /// deliberately no test for it: the local writer takes a typed scope and
    /// `SyncApply.applyConsent` defers an arriving row whose scope does not read
    /// back rather than storing it, so the state cannot be constructed. Asserting
    /// it would mean adding a setter to make the assertion possible, which is a
    /// worse trade than leaving the `guard` unexercised.
    @Test("Every scope a build knows about reads back")
    func everyScopeRoundTrips() {
        for scope in ConsentScope.allCases {
            let row = ConsentRecord(
                scope: scope, kidIDs: [Who.robin], appVersion: "1.0", at: Who.t0)
            #expect(row.recorded == RecordedConsent(scope: scope, kidIDs: [Who.robin]))
        }
    }
}
