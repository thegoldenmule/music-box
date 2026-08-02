import CloudKit
import FamilyStore
import Foundation

/// Which zone a record lives in.
///
/// **The topology is the access control.** CloudKit has no per-record
/// permissions inside a zone — a participant either holds the whole zone or none
/// of it — so anything that must be readable by one person and not another has
/// to be a different zone. That is why this is three shapes rather than one.
///
/// - The **household** zone is the roster, the devices, the gate and the
///   consents. Both parents; no child.
/// - Each kid gets a **policy** zone and a **work** zone. The split exists so a
///   child's own Apple Account can participate in their own data at
///   `.readWrite` for the half that is theirs, while the half that decides what
///   they may reach stays `.readOnly` to them. Without it a child could write
///   the `PolicyEntryRecord`s that govern their own sandbox.
///
/// **The split is also why `SuggestionRecord` is in `work` and not `policy`,
/// which is not where it first looks like it belongs.** A suggestion is a
/// parent's, and folding it into the policy as an allow is exactly what it does
/// — so `policy` is the intuitive home. But `dismiss()` is a *kid-side write*,
/// and dismissal is what withdraws that allow. Read-only would mean the server
/// rejecting a child tapping "no thanks" while the allow stayed live forever.
/// The narrower guarantee — a child cannot write their own policy entries — is
/// kept; the tidier one is not available.
public enum FamilyZone: Sendable, Equatable, Hashable {
    case household
    case kidPolicy(UUID)
    case kidWork(UUID)

    public var zoneName: String {
        switch self {
        case .household: "household"
        case .kidPolicy(let kid): "kid-\(kid.uuidString.lowercased())-policy"
        case .kidWork(let kid): "kid-\(kid.uuidString.lowercased())-work"
        }
    }

    public var id: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Reads a zone back from its name, so an arriving record can say where it
    /// came from without a lookup table.
    public init?(zoneName: String) {
        if zoneName == "household" {
            self = .household
            return
        }
        let parts = zoneName.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.first == "kid", let suffix = parts.last else { return nil }
        let middle = parts.dropFirst().dropLast().joined(separator: "-")
        guard let kid = UUID(uuidString: middle) else { return nil }
        switch suffix {
        case "policy": self = .kidPolicy(kid)
        case "work": self = .kidWork(kid)
        default: return nil
        }
    }

    /// Where a record of this type belongs.
    ///
    /// `nil` when a kid-scoped type arrives without a kid — a record that cannot
    /// be placed, which the caller must hold rather than guess about. Guessing
    /// here would put one child's data in another child's zone.
    public static func placing(_ type: String, kidID: UUID?) -> FamilyZone? {
        switch type {
        case "Family", "GrownUp", "DeviceRecord", "PasscodeEpochRecord", "ConsentRecord":
            return .household

        // What decides what the child may reach. Child `.readOnly`.
        case "Kid", "SandboxSettingRecord", "PolicyEntryRecord", "HistoryClearRecord":
            guard let kidID else { return nil }
            return .kidPolicy(kidID)

        // What the child makes and does. Child `.readWrite`.
        case "FavoriteRecord", "PlaylistRecord", "PlaylistEntryRecord",
            "SuggestionRecord", "SuggestionEntryRecord",
            "ActivitySegmentRecord", "WeeklySummaryRecord":
            guard let kidID else { return nil }
            return .kidWork(kidID)

        default:
            return nil
        }
    }

    /// Whether a child's own account may write here.
    ///
    /// The whole point of the pair. `false` on `policy` is the guarantee that a
    /// child cannot edit the rules that govern them, enforced by CloudKit rather
    /// than by the app choosing not to show a button.
    public var childMayWrite: Bool {
        switch self {
        case .household: false
        case .kidPolicy: false
        case .kidWork: true
        }
    }
}
