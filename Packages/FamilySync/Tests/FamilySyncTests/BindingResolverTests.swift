import Foundation
import Testing

@testable import FamilySync

private enum Fix {
    static let deviceID = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
    static let ada = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!
    static let sam = UUID(uuidString: "5A000000-0000-0000-0000-000000000005")!
    static let dadAccount = "_dad"
    static let mumAccount = "_mum"
    static let adaAccount = "_ada"
}

private func device(
    role: String? = "kidOnly",
    bound: UUID? = Fix.ada,
    enrolledUnder: String? = Fix.dadAccount,
    revoked: Bool = false
) -> DeviceBinding {
    DeviceBinding(
        id: Fix.deviceID,
        role: role,
        boundKidID: bound,
        enrolledAccountRecordName: enrolledUnder,
        isRevoked: revoked
    )
}

private let household = [
    KidBinding(id: Fix.ada, boundAccountRecordName: nil),
    KidBinding(id: Fix.sam, boundAccountRecordName: nil),
]

private func resolve(
    _ d: DeviceBinding?,
    _ account: AccountState,
    kids: [KidBinding] = household,
    passcode: Bool = true
) -> BindingOutcome {
    BindingResolver.resolve(device: d, account: account, kids: kids, hasLocalPasscode: passcode)
}

// MARK: -

@Suite("Which child this device opens")
struct Binding {
    @Test("A device nobody has enrolled runs setup")
    func unenrolled() {
        #expect(resolve(nil, .signedIn(Fix.dadAccount)) == .unenrolled)
    }

    @Test("A parent's device has no player at all")
    func parentOnly() {
        #expect(resolve(device(role: "parentOnly", bound: nil), .signedIn(Fix.dadAccount)) == .parentOnly)
    }

    @Test("The bound child opens under the account it was enrolled with")
    func opensTheBoundKid() {
        #expect(resolve(device(), .signedIn(Fix.dadAccount)) == .open(Fix.ada))
    }

    /// A child carries their account across hardware: on a hand-me-down iPad
    /// signed into their own account, they are that child whatever the iPad was
    /// last set up for.
    @Test("An account binding beats a device binding")
    func accountBeatsDevice() {
        let kids = [
            KidBinding(id: Fix.ada, boundAccountRecordName: nil),
            KidBinding(id: Fix.sam, boundAccountRecordName: Fix.adaAccount),
        ]
        // The device says Ada; the account signed in is Sam's.
        #expect(resolve(device(), .signedIn(Fix.adaAccount), kids: kids) == .open(Fix.sam))
    }

    /// **The clause that matters most.** Opening a different child puts a
    /// different policy level in force, shows another child's library, and files
    /// every play under the wrong name — three failures that all look like the
    /// app working. So a mismatch says both facts and stops.
    @Test("A changed account locks and never falls back to a sibling")
    func accountChangeLocks() {
        let outcome = resolve(device(), .signedIn(Fix.mumAccount))
        #expect(outcome == .locked(.accountChanged(enrolled: Fix.dadAccount, signedIn: Fix.mumAccount)))
    }

    /// Three platform states, one binding state. `restricted` is documented as
    /// what parental controls produce, so on a child's device it is a normal
    /// steady state — the device binding governs and nothing is disturbed.
    @Test("No account is not a mismatch")
    func noAccountIsNotAMismatch() {
        #expect(resolve(device(), .noOpinion) == .open(Fix.ada))
    }

    @Test("A revoked device opens nothing, whatever else is true")
    func revokedOpensNothing() {
        #expect(resolve(device(revoked: true), .signedIn(Fix.dadAccount)) == .locked(.revoked))
        #expect(resolve(device(revoked: true), .noOpinion) == .locked(.revoked))
        // Even when the signed-in account owns a child outright.
        let kids = [KidBinding(id: Fix.sam, boundAccountRecordName: Fix.adaAccount)]
        #expect(resolve(device(revoked: true), .signedIn(Fix.adaAccount), kids: kids) == .locked(.revoked))
    }

    @Test("A device bound to nobody locks rather than picking someone")
    func unboundLocks() {
        #expect(resolve(device(bound: nil), .signedIn(Fix.dadAccount)) == .locked(.notBound))
    }

    /// The child was removed from the household on another device. There is a
    /// tempting fallback here and it is exactly the one that must not exist.
    @Test("A device bound to a child who is gone locks")
    func missingKidLocks() {
        let gone = UUID()
        #expect(
            resolve(device(bound: gone), .signedIn(Fix.dadAccount)) == .locked(.boundKidMissing(gone))
        )
    }

    /// The child's iPad is the device most likely never to have had a passcode
    /// set, and the one the child is holding.
    @Test("A kid binding requires a gate on that device")
    func bindingRequiresAGate() {
        #expect(
            resolve(device(), .signedIn(Fix.dadAccount), passcode: false) == .locked(.noGate(Fix.ada))
        )
    }

    @Test("The gate is required on the account path too")
    func accountPathAlsoNeedsAGate() {
        let kids = [KidBinding(id: Fix.sam, boundAccountRecordName: Fix.adaAccount)]
        #expect(
            resolve(device(), .signedIn(Fix.adaAccount), kids: kids, passcode: false)
                == .locked(.noGate(Fix.sam))
        )
    }

    /// A device enrolled before accounts were recorded. Not a mismatch — there
    /// is nothing to mismatch against.
    @Test("A device with no enrolled account is governed by its binding")
    func noEnrolledAccountIsNotAMismatch() {
        #expect(resolve(device(enrolledUnder: nil), .signedIn(Fix.mumAccount)) == .open(Fix.ada))
    }

    /// The resolver is a function of its arguments and nothing else, so the same
    /// inputs give the same answer every time it is asked.
    @Test("The same inputs always give the same answer")
    func deterministic() {
        let inputs: [(DeviceBinding?, AccountState)] = [
            (device(), .signedIn(Fix.dadAccount)),
            (device(), .signedIn(Fix.mumAccount)),
            (device(), .noOpinion),
            (device(revoked: true), .noOpinion),
            (nil, .noOpinion),
        ]
        for (d, a) in inputs {
            #expect(resolve(d, a) == resolve(d, a))
        }
    }
}
