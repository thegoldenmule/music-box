import Foundation

/// What the household says about its gate, as this rule needs it.
///
/// A value rather than the `@Model`, so the decision below can be exhausted with
/// no store — the same reason `BindingResolver` takes `AccountState`.
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

    /// This device holds the current code. Check what is typed against the local
    /// item, which is the fast path and the offline path.
    case enterLocal

    /// The household has a code this device does not hold — either it never had
    /// one, or the code was rotated somewhere else. Check against the household
    /// verifier, and on success write a local item at that epoch.
    case enterHousehold(epoch: Int)

    /// The Keychain could not be read. Not a state that may offer anything.
    case unavailable
}

/// Whether the code a parent types opens this device, and against what.
///
/// **The rule that makes a rotated passcode mean something on a second device.**
/// Before this, each device had an unrelated local code: changing it on a parent's
/// phone left the child's iPad opening to the old one forever, and there was no
/// revocation path at all — `PasscodeStore.clear()` had no caller anywhere in the
/// app.
///
/// **Pure, and beside the gate rather than inside a view**, for the reason
/// ``BindingResolver`` is: it decides whether the admin surface opens, so it is as
/// safety-critical as anything in this codebase, and there is no app test target.
public enum PasscodeEpoch {
    /// The first epoch a household writes.
    public static let first = 1

    /// What to ask for, given what this device holds and what the household says.
    ///
    /// The clause order is the argument, and two of the four exist only because
    /// collapsing them was a real hole:
    ///
    /// 1. **Unreadable is never absent.** A Keychain that errored used to read like
    ///    a device nobody had set a code on, and the screen that asks is the one
    ///    offering to *choose* — so a transient failure on a device holding a
    ///    family's whole policy set offered to replace the passcode protecting it.
    ///    ``PasscodeAvailability`` exists for this and it is honoured first.
    /// 2. **Choose only when there is no gate anywhere.** A device with no local
    ///    item, in a household that has an epoch, must *enter* — not choose.
    ///    Otherwise joining a family and then setting your own admin code is a
    ///    bypass, and it is the child's own iPad that would do it.
    /// 3. **A local item older than the household's epoch is stale.** The code was
    ///    rotated elsewhere; this device must accept the new one and only the new
    ///    one.
    /// 4. **Equal epochs check locally**, which is what keeps the gate working with
    ///    no network — the ordinary case, and the one that must never depend on
    ///    iCloud being reachable.
    public static func challenge(
        local: PasscodeAvailability,
        localEpoch: Int,
        household: HouseholdGate?
    ) -> PasscodeChallenge {
        if local == .unreadable { return .unavailable }

        guard let household else {
            // No epoch known here. That is either a household that predates the
            // mechanism or one whose record has not arrived — and in both cases a
            // local item is the only authority available, so it governs.
            return local == .configured ? .enterLocal : .choose
        }

        guard local == .configured else { return .enterHousehold(epoch: household.epoch) }
        return localEpoch < household.epoch
            ? .enterHousehold(epoch: household.epoch)
            : .enterLocal
    }

    /// The epoch a rotation should write.
    ///
    /// **Monotonic and derived from what is known**, never a timestamp: two parents
    /// rotating at once produce the same number and one record, which is a conflict
    /// the merge settles, rather than two records whose order depends on a clock.
    public static func next(after household: HouseholdGate?) -> Int {
        guard let household else { return first }
        return household.epoch + 1
    }
}
