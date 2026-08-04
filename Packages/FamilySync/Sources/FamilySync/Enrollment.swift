import Foundation

/// What a device is being set up as.
///
/// Stringly-typed for the reason ``DeviceBinding`` is: this file decides things
/// and must stay reachable without `FamilyStore`, so the raw values cross the
/// boundary rather than the enum. `DeviceRole` is the definition; these are the
/// same strings and there is a test that says so.
public enum EnrollmentRole: String, Sendable, Equatable, CaseIterable {
    case parentOnly
    case kidOnly
    case both

    public var isPlayer: Bool { self != .parentOnly }
}

/// Why a device may not be enrolled the way it was asked to be.
public enum EnrollmentRefusal: Sendable, Equatable {
    /// **The standing hole this type exists to close.** A device bound to a
    /// child, with no passcode on it, is the weakest gate over the most data —
    /// and it is the *likeliest* device to have no code set, because it is the
    /// child's own iPad and a child does not set one.
    ///
    /// `DeviceRecord.bind` documents this rule and cannot enforce it: it has no
    /// idea whether a Keychain on this hardware holds anything. So the rule
    /// lives here, where it is a value that can be tested, rather than in a view
    /// that happens to disable a button.
    case needsPasscode

    /// Pointed at a child who is not in this household.
    case unknownKid(UUID)

    /// A parent's phone has no player, so binding one to a child is not a
    /// stricter setup — it is a contradiction, and silently accepting it would
    /// leave a row whose `role` and `boundKidID` disagree about what it is.
    case parentOnlyCannotBind

    /// Enrolment on a device somebody has already revoked. Restoring it is a
    /// parent's decision from the roster, never a side effect of the device
    /// asking again — otherwise revoking is undone by the child relaunching.
    case revoked
}

// MARK: -

/// Whether a device may be set up as asked.
///
/// **Pure, and beside ``BindingResolver`` on purpose.** That one decides which
/// child a device opens into; this one decides whether it may be pointed at a
/// child at all. Both are safety decisions, both would otherwise live in a view
/// or a `Session` method, and there is no app test target — so anything left up
/// there is untestable by anything that runs off-device.
public enum Enrollment {
    /// `nil` when the enrolment is allowed.
    ///
    /// Order matters and reads as the argument: a revoked device is refused
    /// before anything else is considered, exactly as in `BindingResolver`,
    /// because revocation outranks whatever the device would like to be. Then
    /// the contradiction, then the household membership, and the passcode last
    /// — it is the only one the person in front of the screen can fix on the
    /// spot, so it is the one worth reporting when several are true.
    public static func refusal(
        role: EnrollmentRole,
        boundKidID: UUID?,
        kids: [UUID],
        hasLocalPasscode: Bool,
        isRevoked: Bool = false
    ) -> EnrollmentRefusal? {
        if isRevoked { return .revoked }

        guard let boundKidID else {
            // No child named. Legal for any role: a parent's phone never has
            // one, and a shared iPad may be enrolled before anybody decides
            // whose it is.
            return nil
        }

        if role == .parentOnly { return .parentOnlyCannotBind }
        guard kids.contains(boundKidID) else { return .unknownKid(boundKidID) }
        guard hasLocalPasscode else { return .needsPasscode }
        return nil
    }

    /// Convenience for the screen: whether this combination may be saved.
    public static func isAllowed(
        role: EnrollmentRole,
        boundKidID: UUID?,
        kids: [UUID],
        hasLocalPasscode: Bool,
        isRevoked: Bool = false
    ) -> Bool {
        refusal(
            role: role, boundKidID: boundKidID, kids: kids,
            hasLocalPasscode: hasLocalPasscode, isRevoked: isRevoked) == nil
    }
}

// MARK: -

extension EnrollmentRefusal {
    /// What to put on the screen.
    ///
    /// **Says what to do, not what went wrong.** A parent setting up a child's
    /// iPad and reading "invalid configuration" learns nothing; the passcode
    /// case in particular has a fix that takes ten seconds and they are holding
    /// the device it happens on.
    public var explanation: String {
        switch self {
        case .needsPasscode:
            "Set an admin passcode on this device first. Without one, anybody holding it could change what your child is allowed to reach."
        case .unknownKid:
            "That child isn't in this family any more. Pick somebody else, or add them first."
        case .parentOnlyCannotBind:
            "A grown-up's device doesn't open into a child's player, so it can't be pointed at one. Choose a shared or child's device instead."
        case .revoked:
            "This device was removed from the family. A grown-up can let it back in from the device list."
        }
    }
}
