import Foundation
import Testing

@testable import FamilyStore
@testable import FamilySync

private let ada = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!
private let sam = UUID(uuidString: "5A000000-0000-0000-0000-000000000005")!
private let gone = UUID(uuidString: "60000000-0000-0000-0000-000000000060")!
private let kids = [ada, sam]

@Suite("What a device may be set up as")
struct EnrollmentRules {
    /// **The rule this type exists for, and the hole it closes.** The child's
    /// own iPad is the device least likely to have a passcode set and the one
    /// holding the most of their data — so binding without a gate is the
    /// weakest lock over the most information.
    @Test("A child's device cannot be bound without a passcode on it")
    func kidBindingNeedsAGate() {
        #expect(
            Enrollment.refusal(
                role: .kidOnly, boundKidID: ada, kids: kids, hasLocalPasscode: false)
                == .needsPasscode)

        #expect(
            Enrollment.isAllowed(
                role: .kidOnly, boundKidID: ada, kids: kids, hasLocalPasscode: true))
    }

    /// A shared iPad is the same rule. The role changes what happens on leaving
    /// admin, not whether a child's data is behind a gate.
    @Test("A shared device is held to the same rule")
    func sharedNeedsAGateToo() {
        #expect(
            Enrollment.refusal(role: .both, boundKidID: ada, kids: kids, hasLocalPasscode: false)
                == .needsPasscode)
    }

    /// **No passcode is only a problem when a child is named.** A parent's phone
    /// set up before anybody has chosen a code must still enrol, or setup has an
    /// order nobody was told about.
    @Test("A device with no child needs no passcode")
    func unboundNeedsNothing() {
        #expect(
            Enrollment.refusal(
                role: .parentOnly, boundKidID: nil, kids: kids, hasLocalPasscode: false) == nil)
        #expect(
            Enrollment.refusal(role: .both, boundKidID: nil, kids: kids, hasLocalPasscode: false)
                == nil)
    }

    /// A parent's phone has no player at all, so pointing one at a child is not
    /// a stricter setup — it is a row whose role and binding disagree about what
    /// the device is.
    @Test("A grown-up's device cannot be pointed at a child")
    func parentOnlyCannotBind() {
        #expect(
            Enrollment.refusal(
                role: .parentOnly, boundKidID: ada, kids: kids, hasLocalPasscode: true)
                == .parentOnlyCannotBind)
    }

    @Test("A child who is not in the household is refused by name")
    func unknownKidIsNamed() {
        #expect(
            Enrollment.refusal(
                role: .kidOnly, boundKidID: gone, kids: kids, hasLocalPasscode: true)
                == .unknownKid(gone))
    }

    /// **Revocation outranks everything, including a correct setup.** Otherwise
    /// a parent revokes a device and the child undoes it by relaunching, which
    /// is the one failure that makes the whole roster meaningless.
    @Test("A revoked device cannot enrol its way back in")
    func revocationWins() {
        #expect(
            Enrollment.refusal(
                role: .kidOnly, boundKidID: ada, kids: kids, hasLocalPasscode: true,
                isRevoked: true) == .revoked)

        // Even with nothing else wrong at all.
        #expect(
            Enrollment.refusal(
                role: .parentOnly, boundKidID: nil, kids: kids, hasLocalPasscode: true,
                isRevoked: true) == .revoked)
    }

    /// When more than one is true, the reported one is the one the person
    /// holding the device can act on.
    @Test("The passcode is reported last, because it is the fixable one")
    func fixableRefusalWins() {
        // Unknown kid *and* no passcode: naming the missing child first is
        // right, because setting a code would not make this work.
        #expect(
            Enrollment.refusal(
                role: .kidOnly, boundKidID: gone, kids: kids, hasLocalPasscode: false)
                == .unknownKid(gone))
    }

    /// Every refusal has to say something a parent can act on. An enum case
    /// added without copy is a screen that says nothing.
    @Test("Every refusal explains itself")
    func everyRefusalHasCopy() {
        let all: [EnrollmentRefusal] = [
            .needsPasscode, .unknownKid(ada), .parentOnlyCannotBind, .revoked,
        ]
        for refusal in all {
            #expect(refusal.explanation.isEmpty == false)
            #expect(refusal.explanation.count > 30, "\(refusal) has placeholder copy")
        }
    }
}

// MARK: -

@Suite("The role strings on both sides of the boundary")
struct RoleStrings {
    /// `EnrollmentRole` and `DeviceRole` are the same strings written twice, so
    /// that this file and `BindingResolver` stay free of `FamilyStore`. Two
    /// spellings that drift is a device that enrols as one thing and resolves as
    /// another — and the wrong answer there is a sibling's sandbox.
    @Test("Every enrollment role is a device role, and the reverse")
    func rolesAgree() {
        let enrollment = Set(EnrollmentRole.allCases.map(\.rawValue))
        let device = Set(DeviceRole.allCases.map(\.rawValue))
        #expect(enrollment == device)
    }

    /// `BindingResolver` compares `device.role == "parentOnly"` against a raw
    /// string. That literal has to be the same one.
    @Test("The string BindingResolver checks is the parent-only role")
    func parentOnlyStringMatches() {
        let binding = DeviceBinding(
            id: UUID(), role: EnrollmentRole.parentOnly.rawValue, boundKidID: nil,
            enrolledAccountRecordName: nil, isRevoked: false)

        #expect(
            BindingResolver.resolve(
                device: binding, account: .noOpinion, kids: [], hasLocalPasscode: true)
                == .parentOnly)
    }

    /// And a player role must *not* take that branch, or every device would be
    /// a parent's and no child would ever get a screen.
    @Test("A player role is not parent-only")
    func playerRoleIsNotParentOnly() {
        for role in EnrollmentRole.allCases where role.isPlayer {
            let binding = DeviceBinding(
                id: UUID(), role: role.rawValue, boundKidID: ada,
                enrolledAccountRecordName: nil, isRevoked: false)

            #expect(
                BindingResolver.resolve(
                    device: binding, account: .noOpinion, kids: [KidBinding(id: ada)],
                    hasLocalPasscode: true) == .open(ada))
        }
    }
}

// MARK: -

@Suite("This device's own identity")
struct DeviceIdentityTests {
    /// Minted once and kept. A device that mints a new one every launch is a
    /// roster that grows by one row per launch and a binding that never holds.
    @Test("The identifier is stable across reads")
    func identityIsStable() throws {
        let store = InMemoryDeviceIdentity()
        let first = try store.identifier()
        #expect(try store.identifier() == first)
        #expect(try store.identifier() == first)
    }

    @Test("Two devices do not share an identity")
    func identitiesAreDistinct() throws {
        #expect(try InMemoryDeviceIdentity().identifier() != InMemoryDeviceIdentity().identifier())
    }

    /// **Failing to read must not read as "new".** The unenrolled path *writes a
    /// row*, so a device that cannot reach its Keychain and falls through to it
    /// enrols again on every launch. Throwing is what makes that a startup error
    /// instead of a roster nobody can read.
    @Test("A Keychain that cannot be read throws rather than minting")
    func unreadableIdentityThrows() {
        #expect(throws: (any Error).self) { try FailingDeviceIdentity().identifier() }
    }
}

// MARK: -

@Suite("What the platform says about the account")
struct AccountIdentityTests {
    /// The three unhappy platform answers are one binding state, and the stub
    /// has to be able to produce it — most of what needs testing above this line
    /// is what happens when nobody is signed in.
    @Test("A stub can produce either state")
    func stubProducesBoth() async {
        #expect(await StubAccountIdentity(.noOpinion).current() == .noOpinion)
        #expect(await StubAccountIdentity(.signedIn("_abc")).current() == .signedIn("_abc"))
    }

    /// The pairing that matters: no opinion from the platform must leave a bound
    /// device open rather than locking a child out of their own player because
    /// iCloud was unreachable.
    @Test("No account does not lock a bound device")
    func noOpinionKeepsThePlayerOpen() async {
        let account = await StubAccountIdentity(.noOpinion).current()
        let binding = DeviceBinding(
            id: UUID(), role: EnrollmentRole.kidOnly.rawValue, boundKidID: ada,
            enrolledAccountRecordName: "_enrolled", isRevoked: false)

        #expect(
            BindingResolver.resolve(
                device: binding, account: account, kids: [KidBinding(id: ada)],
                hasLocalPasscode: true) == .open(ada))
    }
}
