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
    /// No per-adult scoping: a participant holds the household and every child's zone.
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

    /// `SharePlan.grants` returns nothing outside the household to consent to.
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

    /// The case this type exists for: "already agreed" would leak a sibling's history.
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

    /// The child-account ask is larger: it makes a minor's own account a participant.
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

    /// Set arithmetic, not a special case — nothing to agree about with no children.
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

    /// No test for an unreadable `scopeRaw`: only a typed scope can ever be written.
    @Test("Every scope a build knows about reads back")
    func everyScopeRoundTrips() {
        for scope in ConsentScope.allCases {
            let row = ConsentRecord(
                scope: scope, kidIDs: [Who.robin], appVersion: "1.0", at: Who.t0)
            #expect(row.recorded == RecordedConsent(scope: scope, kidIDs: [Who.robin]))
        }
    }
}
