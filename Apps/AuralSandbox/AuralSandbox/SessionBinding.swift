import AdminGate
import FamilyStore
import FamilySync
import Foundation
import SwiftData

/// Which child this device opens into, and how it comes to be enrolled.
///
/// **Separate from `Session` because the decision is not here.**
/// ``BindingResolver`` and ``Enrollment`` hold the rules and are tested with no
/// device, no account and no network; what is left in this file is reading the
/// three inputs and writing the answer down. That split is the whole reason
/// those types exist — there is no app test target, so a rule that lives in a
/// `Session` method is a rule nothing can check.
@MainActor
extension Session {
    /// Reads this device's identity, asks who is signed in, and resolves.
    ///
    /// **Called on every launch, and it writes.** A device that is already
    /// enrolled has its `lastSeenAt` stamped and — if it did not know before —
    /// the account it is running under recorded. That second one matters: a row
    /// created before anybody was signed in would otherwise never learn its
    /// account, and the account is what `BindingResolver` uses to notice a
    /// hand-me-down.
    func resolveBinding() async {
        let identity: UUID
        do {
            identity = try deviceIdentity.identifier()
        } catch {
            // **Not `.unenrolled`.** That path writes a row, so a device that
            // cannot read its own Keychain would enrol again on every launch and
            // fill the roster. Refusing is the recoverable failure.
            applyBinding(
                .locked(.notBound), device: nil, account: .noOpinion,
                trouble:
                    "This device can't read its own identity, so it can't tell which child it belongs to."
            )
            return
        }

        let account = await accountIdentity.current()
        let row = deviceRecord(id: identity)

        if let row {
            row.sawActivity()
            if row.enrolledAccountRecordName == nil, case .signedIn(let name) = account {
                row.enrolled(under: name)
            }
            commitDeviceChanges()
        }

        let outcome = BindingResolver.resolve(
            device: row.map(Self.asBinding),
            account: account,
            kids: kids.map {
                KidBinding(id: $0.id, boundAccountRecordName: $0.boundAccountRecordName)
            },
            hasLocalPasscode: isPasscodeSet
        )
        applyBinding(outcome, device: row, account: account)

        // After `applyBinding`, because that is what makes the account readable,
        // and every launch rather than once: an adult who was claimed on a build
        // before this existed has no account against them, and the roster on the
        // *other* parent's phone is what pays for it. Writes nothing when the
        // answer is unchanged.
        claimAccountForActingGrownUp()

        // A bound device opens into *its* child rather than whoever the roster
        // happens to list first — which is the entire point, and was
        // `family.kids.first` on an unordered relationship until now.
        if case .open(let kidID) = outcome, let bound = kids.first(where: { $0.id == kidID }) {
            if bound.id != kid.id { switchTo(bound) }
        }
    }

    /// Sets this device up, or changes what it is.
    ///
    /// Refuses through ``Enrollment`` rather than by disabling a button: the
    /// screen and the rule are different things, and only one of them is
    /// testable.
    @discardableResult
    func enroll(
        role: EnrollmentRole,
        label: String,
        boundKidID: UUID?
    ) -> EnrollmentRefusal? {
        let identity: UUID
        do { identity = try deviceIdentity.identifier() } catch { return .revoked }

        let existing = deviceRecord(id: identity)
        if let refusal = Enrollment.refusal(
            role: role,
            boundKidID: boundKidID,
            kids: kids.map(\.id),
            hasLocalPasscode: isPasscodeSet,
            isRevoked: existing?.isRevoked ?? false
        ) {
            return refusal
        }

        let accountName: String? =
            if case .signedIn(let name) = signedInAccount { name } else { nil }

        if let existing {
            existing.rename(to: label)
            existing.bind(kidID: boundKidID)
            existing.enrolled(under: accountName)
        } else {
            let record = DeviceRecord(
                id: identity,
                familyID: householdID,
                label: label,
                role: DeviceRole(rawValue: role.rawValue) ?? .parentOnly,
                platform: Self.platform,
                boundKidID: boundKidID,
                enrolledAccountRecordName: accountName,
                enrolledByGrownUpID: actingGrownUp?.id
            )
            addDevice(record)
        }

        commitDeviceChanges()
        Task { await resolveBinding() }
        return nil
    }

    // MARK: - The roster, from behind the gate

    /// Whether this row describes the device the parent is holding.
    func isThisDevice(_ device: DeviceRecord) -> Bool {
        device.id == deviceRow?.id
    }

    /// Takes a device out of the family.
    ///
    /// **Refuses the device in your hand, and that is not politeness.** Revocation
    /// locks a device into a dead end by design — `BindingResolver` puts
    /// `.revoked` above every other clause so the device can read the tombstone
    /// about itself — and the way back is this screen, which is behind the gate,
    /// which is behind the player that has just been withheld. On a family with
    /// one device that is unrecoverable. `DeviceLockedView`'s own copy already
    /// says "from the device list **on another device**"; this is the half that
    /// makes that sentence true.
    func revoke(_ device: DeviceRecord) -> String? {
        if isThisDevice(device) {
            return
                "You can't remove the device you're using. Do it from another grown-up's device, or this one would lock itself out with no way back in."
        }
        device.revoke()
        commitDeviceChanges()
        return nil
    }

    /// Lets a revoked device back in.
    ///
    /// Deliberately a parent's decision here and never a side effect of the device
    /// asking again — otherwise revoking is undone by a child relaunching.
    func restore(_ device: DeviceRecord) {
        device.restore()
        commitDeviceChanges()
    }

    /// Changes what this device is for.
    ///
    /// **This device only, and that is not an oversight.** `DeviceRecord.roleRaw`
    /// has no setter — the role is what a device was set up as, and the setup
    /// screen is unreachable once enrolled, which is the hole this closes. Doing it
    /// for a *remote* device would need a new writer on the model and would be the
    /// wrong shape anyway: `parentOnly` means "no player on this hardware", and
    /// deciding that about a device you are not holding is how an iPad ends up
    /// with no player and nobody near it to notice.
    ///
    /// Through ``enroll(role:label:boundKidID:)``, so ``FamilySync/Enrollment``
    /// judges it and the binding re-resolves at once.
    func setRole(_ role: EnrollmentRole, on device: DeviceRecord) -> EnrollmentRefusal? {
        guard isThisDevice(device) else { return nil }
        // A grown-up's device has no player, so it cannot point at a child. Kept
        // here rather than left to the refusal, because a parent changing the role
        // has not asked to be told about a binding they are abandoning.
        return enroll(
            role: role,
            label: device.label,
            boundKidID: role.isPlayer ? device.boundKidID : nil
        )
    }

    func rename(_ device: DeviceRecord, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        device.rename(to: trimmed)
        commitDeviceChanges()
    }

    /// Points a device at a child, from any device in the family.
    ///
    /// **This device goes through ``enroll(role:label:boundKidID:)``** so the
    /// local rules run and the binding is re-resolved immediately — a parent who
    /// changes which child this iPad opens into should see it happen, not on the
    /// next launch.
    ///
    /// Another device is a plain write, because `boundKidID` is the household's
    /// answer and syncs. Two of `Enrollment`'s refusals are household facts and
    /// are checked here. The passcode one is a fact about *that* device's
    /// Keychain, which nothing here can read — it is not skipped, it is enforced
    /// where the answer exists: the target device re-runs the same rule through
    /// `BindingResolver` on its next launch and locks itself on `.noGate` rather
    /// than opening a child's player without a gate over it.
    func rebind(_ device: DeviceRecord, to kidID: UUID?) -> EnrollmentRefusal? {
        let role = EnrollmentRole(rawValue: device.roleRaw) ?? .parentOnly

        if isThisDevice(device) {
            return enroll(role: role, label: device.label, boundKidID: kidID)
        }

        if let refusal = Enrollment.refusal(
            role: role,
            boundKidID: kidID,
            kids: kids.map(\.id),
            hasLocalPasscode: true,
            isRevoked: device.isRevoked
        ) {
            return refusal
        }

        device.bind(kidID: kidID)
        commitDeviceChanges()
        return nil
    }

    /// What to suggest calling this device, before a parent renames it.
    static var suggestedDeviceLabel: String {
        #if os(macOS)
            return "This Mac"
        #else
            return UIDevice.current.name
        #endif
    }

    private static var platform: DevicePlatform {
        #if os(macOS)
            return .mac
        #else
            return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }

    private static func asBinding(_ row: DeviceRecord) -> DeviceBinding {
        DeviceBinding(
            id: row.id,
            role: row.roleRaw,
            boundKidID: row.boundKidID,
            enrolledAccountRecordName: row.enrolledAccountRecordName,
            isRevoked: row.isRevoked
        )
    }
}

#if canImport(UIKit)
    import UIKit
#endif
