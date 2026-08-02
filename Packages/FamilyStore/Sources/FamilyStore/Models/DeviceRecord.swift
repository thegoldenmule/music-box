import Foundation
import SwiftData

/// What a device is for. Chosen during setup, **never inferred**.
///
/// Names taken from the spec unchanged, including `both` — it reads worse than
/// `shared` and is what the design of record calls it, and a rename that only
/// this file knows about is how a stored raw value drifts from the document
/// that explains it.
public enum DeviceRole: String, Sendable, CaseIterable {
    /// No player at all. A parent's phone.
    case parentOnly
    /// Launches into the player; admin behind the gate. A child's own iPad.
    case kidOnly
    /// A shared iPad. Same as `kidOnly` on launch — the difference is that
    /// leaving admin restores the bound kid rather than staying where the
    /// parent was.
    case both
}

/// Roughly what the device is, for a roster a parent reads. Not a capability.
public enum DevicePlatform: String, Sendable, CaseIterable {
    case phone
    case pad
    case mac
}

/// One device that has been enrolled in this household.
///
/// **This is where "kid profiles tied to devices" lands, and there was nowhere
/// for it to go.** `DeviceRole`, `AccountSetup` and `DeviceConfiguration` are
/// specified in the wiki and appear in no Swift file; the active kid was
/// `family.kids.first` on an unordered relationship, and the choice was never
/// persisted anywhere. Once that relationship is CloudKit-backed, `first` is not
/// a choice anybody made — and a seven-year-old's iPad opening into his
/// twelve-year-old sister's `reportOnly` sandbox is the wrong policy level,
/// another child's library, and every play filed under the wrong name, all three
/// of which look like the app working.
///
/// **Identity syncs; state does not.** Every field here is the same fact from
/// either parent's phone — that is the test for anything added to it. What a
/// device needs in order to *run* stays local and out of this record: the
/// passcode, the play queue, `DeviceLibraryState`, `ActingGrownUp`, and the
/// binding cache. If two devices would legitimately hold different values for
/// something, it is state and does not belong here.
///
/// **Points at the household by identifier rather than by relationship.** No
/// `Family` inverse, deliberately: the sync mapper's rule is that every
/// cross-record link is a plain identifier, because a device row lives in the
/// household zone while a kid row lives in that kid's, and a SwiftData
/// relationship whose two ends are in zones a given device does not both hold
/// resolves to nil there. Keeping it a column means the local store and the
/// wire agree.
@Model
public final class DeviceRecord {
    /// Minted by the device itself, into its own Keychain, and by nothing else.
    ///
    /// Never `identifierForVendor`: it does not exist on native macOS, and Apple
    /// documents it as changing on Xcode and ad-hoc installs and as nil before
    /// first unlock. A device that reads an empty Keychain registers as **new**
    /// rather than adopting a row — the failure mode of guessing is one child's
    /// iPad silently inheriting another's binding, so duplicates are a parent's
    /// to merge by hand.
    public private(set) var id: UUID = UUID()

    /// Which household. See the note on this type about identifiers.
    public private(set) var familyID: UUID?

    /// What a parent calls it. Human-renameable *because* the identifier will
    /// occasionally churn, and a roster with two "Sam's iPad" rows needs to be
    /// something a person can tidy.
    public private(set) var label: String = ""

    /// ``DeviceRole/rawValue``. Stored as a string with a nil-returning read,
    /// like every other enum in this store — a raw value a future build writes
    /// must not trap an older one.
    public private(set) var roleRaw: String = DeviceRole.parentOnly.rawValue

    /// ``DevicePlatform/rawValue``. Decoration; a row that does not read back
    /// loses an icon and nothing else.
    public private(set) var platformRaw: String = DevicePlatform.pad.rawValue

    /// Which child this device opens into. `nil` on `parentOnly`, and on a
    /// device that has been enrolled but not yet pointed at anybody.
    ///
    /// **The assignment, not the selection.** This is the household's answer and
    /// it is set behind the gate. Which kid is on screen *right now* is a
    /// device fact and stays out of this store.
    public private(set) var boundKidID: UUID?

    /// The Apple Account this device was enrolled under, opaque record name
    /// only. A device binding governs only under the account it was enrolled
    /// with — a disagreement locks the device rather than opening a sibling.
    public private(set) var enrolledAccountRecordName: String?

    /// Which grown-up set it up. For the roster, not for permission.
    public private(set) var enrolledByGrownUpID: UUID?

    public private(set) var enrolledAt: Date = Date.distantPast

    /// Last time this device said anything. Drives "last heard from 4 minutes
    /// ago" in admin, which is the only honest way to show a parent that a deny
    /// has not reached a device yet.
    public private(set) var lastSeenAt: Date = Date.distantPast

    /// **A tombstone, and the one removal in this store that must not delete.**
    ///
    /// Everywhere else here, detaching a row without deleting it is the bug. Not
    /// here: a deleted row is simply re-created by the device on its next
    /// launch, so a delete silently un-revokes itself. The device has to be able
    /// to read the revocation *about itself*, which means the row has to still
    /// be there to read.
    public private(set) var revokedAt: Date?

    public private(set) var modifiedAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        familyID: UUID? = nil,
        label: String,
        role: DeviceRole,
        platform: DevicePlatform,
        boundKidID: UUID? = nil,
        enrolledAccountRecordName: String? = nil,
        enrolledByGrownUpID: UUID? = nil,
        at: Date = .now
    ) {
        self.id = id
        self.familyID = familyID
        self.label = label
        self.roleRaw = role.rawValue
        self.platformRaw = platform.rawValue
        self.boundKidID = boundKidID
        self.enrolledAccountRecordName = enrolledAccountRecordName
        self.enrolledByGrownUpID = enrolledByGrownUpID
        self.enrolledAt = at
        self.lastSeenAt = at
        self.modifiedAt = at
    }

    // MARK: - Reading

    /// `nil` when the stored value does not read back.
    ///
    /// The caller decides what that means, and the two callers decide
    /// differently: a roster shows the row without an icon, while anything
    /// resolving a binding treats an unreadable role as **not a player** — the
    /// same fail-closed direction the rest of this store takes.
    public var role: DeviceRole? { DeviceRole(rawValue: roleRaw) }

    public var platform: DevicePlatform? { DevicePlatform(rawValue: platformRaw) }

    /// Whether this device may still open anything.
    public var isRevoked: Bool { revokedAt != nil }

    // MARK: - Writing

    public func rename(to newLabel: String, at: Date = .now) {
        label = newLabel
        modifiedAt = at
    }

    /// Points the device at a child, or at nobody.
    ///
    /// The caller is responsible for the rule this record cannot enforce:
    /// **enrolment refuses to bind a kid until a passcode exists on that
    /// device.** That closes the standing hole where the child's iPad — the one
    /// most likely never to have had a code set, and the one the child is
    /// holding — is the device with the weakest gate over the most data.
    public func bind(kidID: UUID?, at: Date = .now) {
        boundKidID = kidID
        modifiedAt = at
    }

    public func sawActivity(at: Date = .now) {
        lastSeenAt = at
        modifiedAt = at
    }

    /// Revokes the device. See ``revokedAt`` for why this is not a delete.
    public func revoke(at: Date = .now) {
        guard revokedAt == nil else { return }
        revokedAt = at
        modifiedAt = at
    }

    /// Un-revokes a device a parent revoked by mistake.
    public func restore(at: Date = .now) {
        revokedAt = nil
        modifiedAt = at
    }

    /// Records which Apple Account this device is running under.
    public func enrolled(under recordName: String?, at: Date = .now) {
        enrolledAccountRecordName = recordName
        modifiedAt = at
    }
}
