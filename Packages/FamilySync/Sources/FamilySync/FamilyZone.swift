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
/// ## What is assumed here, and what is documented
///
/// **Apple Family Sharing grants nothing in CloudKit.** The two systems are
/// unrelated, and this is worth stating because the shorthand "the family can
/// see it" is wrong in a way that reads as right. Every participant is
/// explicitly invited and must accept — Apple's *Sharing CloudKit Data with
/// Other iCloud Users* has both accounts logging in on separate devices and a
/// link sent between them. There is no membership that confers access.
///
/// So the working assumption is narrower than it sounds: **an adult who has
/// been invited and has accepted, holding `readWrite`, can write.** That half
/// is documented — Apple's sample has device B editing a shared record and the
/// change landing in device A's private database.
///
/// **What is still unverified is the zone-wide part specifically.** Apple's
/// article describes *hierarchy* sharing: a root record, with children pulled
/// in by `newNoteRecord.parent = CKRecord.Reference(...)`. This design uses
/// `CKShare(recordZoneID:)` instead, which is a different API and the one with
/// reported participant-write trouble. Nothing above tells us it works.
///
/// **There is no fallback, by decision.** Hierarchy sharing was briefly written
/// down as one, and it is not: it needs parent references, and `RecordMapper`
/// forbids references outright — that rule is precisely what lets a kid's rows
/// sit in a different zone from the household they point at. It would pull the
/// reachable graph into one zone and take the per-kid `policy`/`work` split
/// with it, which is the split stopping a child from writing their own policy
/// entries. So this design commits to zone-wide sharing with an explicit invite
/// flow, and if the participant-write probe comes back negative the answer is a
/// redesign rather than a switch. Do not write a second path on the strength of
/// it being cheap; it is not.
///
/// **One thing to get right when the invite is built:** Apple's sample sets
/// `share.publicPermission = .readWrite`, which means anyone holding the link
/// can write. For a store holding a child's search history that is the wrong
/// default. Participants are added explicitly; the link is not the credential.
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

    /// This zone's record ID, for a household owned by `owner`.
    ///
    /// **There is deliberately no zero-argument version.** It used to be a
    /// property that supplied `CKCurrentUserDefaultName`, which is right on the
    /// device that created the household and wrong on every device that joined
    /// one — and wrong in the worst way, because CloudKit answers a request for
    /// a zone you claim to own by creating it. See ``HouseholdSide``. Requiring
    /// the owner name makes each call site say which household it means.
    public func id(ownedBy owner: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: owner)
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
