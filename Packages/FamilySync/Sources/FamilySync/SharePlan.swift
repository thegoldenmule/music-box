import CloudKit
import Foundation

/// What a participant may do in a zone.
public enum SharePermission: Sendable, Equatable {
    case readOnly
    case readWrite

    var ck: CKShare.ParticipantPermission {
        switch self {
        case .readOnly: .readOnly
        case .readWrite: .readWrite
        }
    }
}

/// Who is being invited.
public enum ShareRole: Sendable, Equatable {
    /// Another adult. Sees the whole household and every child in it.
    case coParent
    /// A child, on their own Apple Account. Sees their own two zones and
    /// nothing else — not the household, not a sibling.
    case child(UUID)
}

/// One zone a participant gets, and on what terms.
public struct ZoneGrant: Sendable, Equatable {
    public let zone: FamilyZone
    public let permission: SharePermission

    public init(zone: FamilyZone, permission: SharePermission) {
        self.zone = zone
        self.permission = permission
    }
}

/// Which zones an invitation has to cover.
///
/// **This is the access-control matrix, and it is the reason it is a pure
/// function.** CloudKit has no per-record permissions, so who-sees-what is
/// decided entirely by which zones a participant is added to and at what
/// permission. Getting a row wrong here is not a UI bug — it is a sibling
/// reading another child's search history, or a child editing the rules that
/// govern them. Nothing about it needs a network, so nothing about it should be
/// discovered on a device.
///
/// It also exists because a zone-wide share is **per zone**. A household with
/// two children has five zones, so "invite the other parent" is five grants,
/// not one. That arithmetic is easy to get wrong by hand and impossible to see
/// afterwards, since a missing grant looks exactly like a co-parent whose data
/// has not finished arriving.
public enum SharePlan {
    /// Every zone this role needs, and the permission for each.
    public static func grants(for role: ShareRole, kids: [UUID]) -> [ZoneGrant] {
        switch role {
        case .coParent:
            // The household, then both zones of every child. An adult who can
            // curate for one child and not another is not a thing this design
            // offers — see the spec on why per-adult scoping would be view
            // gating dressed as permission.
            return [ZoneGrant(zone: .household, permission: .readWrite)]
                + kids.flatMap {
                    [
                        ZoneGrant(zone: .kidPolicy($0), permission: .readWrite),
                        ZoneGrant(zone: .kidWork($0), permission: .readWrite),
                    ]
                }

        case .child(let kid):
            // **Read-only on their own policy, and nothing at all anywhere
            // else.** The read-only half is the guarantee that a child cannot
            // edit what they may reach, enforced by CloudKit rather than by the
            // app declining to draw a button. The nothing-else half is why the
            // household zone holds the roster, the devices and the passcode
            // epoch: a child's device never receives any of it.
            guard kids.contains(kid) else { return [] }
            return [
                ZoneGrant(zone: .kidPolicy(kid), permission: .readOnly),
                ZoneGrant(zone: .kidWork(kid), permission: .readWrite),
            ]
        }
    }

    /// Every zone a household owns, which is what has to exist before anything
    /// can be shared.
    public static func zones(kids: [UUID]) -> [FamilyZone] {
        [.household] + kids.flatMap { [FamilyZone.kidPolicy($0), .kidWork($0)] }
    }
}

extension SharePlan {
    /// The zone whose share carries the invitation link.
    ///
    /// **A link carries one share, and a household has more than one zone.** So
    /// an invitation is always an anchor plus a second step: the invitee joins
    /// one share by tapping, and the owner adds them to the rest once they have
    /// an identity to add. The anchor has to be a zone the role actually gets,
    /// or the link points at something they may not have.
    ///
    /// A child's anchor is their **work** zone rather than their policy zone.
    /// Either would do for joining, and work is the half they may write — so if
    /// the second step never runs, a child is left able to keep their own
    /// favorites and unable to see their own rules, which is the harmless way
    /// round. The reverse would leave them holding the rules and unable to save
    /// anything.
    public static func anchor(for role: ShareRole) -> FamilyZone {
        switch role {
        case .coParent: .household
        case .child(let kid): .kidWork(kid)
        }
    }

    /// Everything the anchor did not cover.
    ///
    /// What the second step has to grant. Empty for a household with no
    /// children, which is the one case where an invitation is complete on
    /// acceptance.
    public static func grantsAfterAnchor(for role: ShareRole, kids: [UUID]) -> [ZoneGrant] {
        let anchor = anchor(for: role)
        return grants(for: role, kids: kids).filter { $0.zone != anchor }
    }
}
