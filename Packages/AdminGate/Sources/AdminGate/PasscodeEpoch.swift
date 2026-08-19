import Foundation

/// A value, not the `@Model`, so the decision below tests with no store.
public struct HouseholdGate: Sendable, Equatable {
    public let epoch: Int
    public let verifier: PasscodeVerifier

    public init(epoch: Int, verifier: PasscodeVerifier) {
        self.epoch = epoch
        self.verifier = verifier
    }
}

/// What the gate must do before it opens.
public enum PasscodeChallenge: Sendable, Equatable {
    /// Nobody has ever set a code. The only state that may offer to **choose** one.
    case choose

    /// Fast, offline path: checks against the local item.
    case enterLocal

    /// No code, or rotated elsewhere: check household verifier, then write locally.
    case enterHousehold(epoch: Int)

    /// The Keychain could not be read. Not a state that may offer anything.
    case unavailable
}

/// Pure, beside the gate like `BindingResolver` — same reason: no app test target.
public enum PasscodeEpoch {
    /// The first epoch a household writes.
    public static let first = 1

    /// Clause order fixes two holes: unreadable-as-absent, self-choose bypass.
    public static func challenge(
        local: PasscodeAvailability,
        localEpoch: Int,
        household: HouseholdGate?
    ) -> PasscodeChallenge {
        if local == .unreadable { return .unavailable }

        guard let household else {
            // No epoch known yet — predates it, or hasn't synced — so the local item governs.
            return local == .configured ? .enterLocal : .choose
        }

        guard local == .configured else { return .enterHousehold(epoch: household.epoch) }
        return localEpoch < household.epoch
            ? .enterHousehold(epoch: household.epoch)
            : .enterLocal
    }

    /// Monotonic, not a timestamp: concurrent rotations agree on one number.
    public static func next(after household: HouseholdGate?) -> Int {
        guard let household else { return first }
        return household.epoch + 1
    }
}
