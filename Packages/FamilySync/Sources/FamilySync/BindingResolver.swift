import Foundation

/// What the platform says about the signed-in Apple Account.
public enum AccountState: Sendable, Equatable {
    /// Signed in, with this opaque record name.
    case signedIn(String)

    /// **Three platform states, one binding state: no opinion.** Not signed in,
    /// blocked by parental controls, or temporarily unreachable. None of them is
    /// a *mismatch*, and `restricted` is documented as exactly what parental
    /// controls produce — so on a child's device it is a normal steady state
    /// rather than a fault. The kid player must never surface it, and nothing
    /// may be deleted because of it.
    case noOpinion
}

/// This device's row, as the resolver needs it.
public struct DeviceBinding: Sendable, Equatable {
    public let id: UUID
    public let role: String?
    public let boundKidID: UUID?
    public let enrolledAccountRecordName: String?
    public let isRevoked: Bool

    public init(
        id: UUID,
        role: String?,
        boundKidID: UUID?,
        enrolledAccountRecordName: String?,
        isRevoked: Bool
    ) {
        self.id = id
        self.role = role
        self.boundKidID = boundKidID
        self.enrolledAccountRecordName = enrolledAccountRecordName
        self.isRevoked = isRevoked
    }
}

/// One child, as the resolver needs them.
public struct KidBinding: Sendable, Equatable {
    public let id: UUID
    public let boundAccountRecordName: String?

    public init(id: UUID, boundAccountRecordName: String? = nil) {
        self.id = id
        self.boundAccountRecordName = boundAccountRecordName
    }
}

/// Why a device will not open anything.
public enum LockReason: Sendable, Equatable {
    /// Signed into a different Apple Account than the one this device was
    /// enrolled under.
    case accountChanged(enrolled: String, signedIn: String)
    /// A parent revoked this device.
    case revoked
    /// Bound to a child who is no longer in the household.
    case boundKidMissing(UUID)
    /// Enrolled, but nobody has said which child it is for.
    case notBound
    /// Bound to a child, with no passcode on this device to get behind.
    case noGate(UUID)
}

public enum BindingOutcome: Sendable, Equatable {
    /// Open this child's player.
    case open(UUID)
    /// A parent's device. No player surface at all.
    case parentOnly
    /// Nothing here yet — run setup.
    case unenrolled
    /// Refuse, and say both facts. Never open something else.
    case locked(LockReason)
}

/// Which child this device opens into.
///
/// **A pure value type, for the same reason `PolicyEngine` is one**: this
/// decides *which policy is in force*, which makes it as safety-critical as the
/// engine that then applies it, and the wrong answer here is three failures at
/// once — the wrong sandbox level, another child's library, and every play filed
/// under the wrong name. All three look like the app working. There is no app
/// test target, so anything left in `Session` is untestable by anything
/// available off-device.
public enum BindingResolver {
    /// The whole precedence rule.
    ///
    /// The order of the clauses is the design. Reading top to bottom:
    ///
    /// 1. **A revoked device opens nothing**, before anything else is
    ///    considered. Revocation is a tombstone rather than a delete precisely
    ///    so the device can read it about itself.
    /// 2. **An account binding beats a device binding**, because a child carries
    ///    it across hardware: a kid on a hand-me-down iPad signed into their own
    ///    account is that child, whatever the iPad was last set up for.
    /// 3. **A device binding governs only under the account it was enrolled
    ///    with.** A device signed into a different account than it was set up
    ///    under has had something happen to it that nobody told us about.
    /// 4. **A mismatch locks. It never switches and never falls back.** There is
    ///    no nearest-kid, no first-kid, no last-kid anywhere in here.
    /// 5. **No account is not a mismatch** — see ``AccountState/noOpinion``. The
    ///    device binding governs and the app runs on its last imported data.
    /// 6. **A kid binding requires a gate on that device**, which closes the
    ///    standing hole where the child's iPad is the device most likely never
    ///    to have had a passcode set and the one the child is holding.
    public static func resolve(
        device: DeviceBinding?,
        account: AccountState,
        kids: [KidBinding],
        hasLocalPasscode: Bool
    ) -> BindingOutcome {
        guard let device else { return .unenrolled }
        guard !device.isRevoked else { return .locked(.revoked) }

        if device.role == "parentOnly" { return .parentOnly }

        // 2. The account's own claim, which outranks the device's.
        if case .signedIn(let signedIn) = account,
            let owned = kids.first(where: { $0.boundAccountRecordName == signedIn })
        {
            return gated(owned.id, hasLocalPasscode: hasLocalPasscode)
        }

        // 3 and 4. The device was set up under an account, and a different one
        // is signed in now. Something happened to this device that nobody told
        // us about — a hand-me-down, a sale, a parent switching accounts between
        // launches. It does not get to guess.
        if case .signedIn(let signedIn) = account,
            let enrolled = device.enrolledAccountRecordName,
            enrolled != signedIn
        {
            return .locked(.accountChanged(enrolled: enrolled, signedIn: signedIn))
        }

        // 5. No opinion from the platform: the device binding alone governs.
        guard let boundKidID = device.boundKidID else { return .locked(.notBound) }
        guard kids.contains(where: { $0.id == boundKidID }) else {
            return .locked(.boundKidMissing(boundKidID))
        }

        return gated(boundKidID, hasLocalPasscode: hasLocalPasscode)
    }

    private static func gated(_ kidID: UUID, hasLocalPasscode: Bool) -> BindingOutcome {
        hasLocalPasscode ? .open(kidID) : .locked(.noGate(kidID))
    }
}
