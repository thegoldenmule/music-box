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
            hasLocalPasscode: passcodes.isConfigured
        )
        applyBinding(outcome, device: row, account: account)

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
            hasLocalPasscode: passcodes.isConfigured,
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
