import Foundation
import SwiftData

/// `both` keeps the spec's name; a local rename would drift from the doc.
public enum DeviceRole: String, Sendable, CaseIterable {
    /// No player at all. A parent's phone.
    case parentOnly
    /// Launches into the player; admin behind the gate. A child's own iPad.
    case kidOnly
    /// Same as kidOnly on launch — admin restores the bound kid, not the parent.
    case both
}

/// Roughly what the device is, for a roster a parent reads. Not a capability.
public enum DevicePlatform: String, Sendable, CaseIterable {
    case phone
    case pad
    case mac
}

/// Identity syncs, state does not — device-local facts stay out of this record.
@Model
public final class DeviceRecord {
    /// Minted locally into Keychain; empty reads as new, never guessed onto another's.
    public private(set) var id: UUID = UUID()

    /// Which household. See the note on this type about identifiers.
    public private(set) var familyID: UUID?

    /// Human-renameable — the identifier churns; duplicate labels need tidying.
    public private(set) var label: String = ""

    /// A raw string, nil-returning, so a newer build's value can't trap an older one.
    public private(set) var roleRaw: String = DeviceRole.parentOnly.rawValue

    /// Decoration only; an unreadable row just loses its icon.
    public private(set) var platformRaw: String = DevicePlatform.pad.rawValue

    /// The household's assignment, set behind the gate — not who is on screen now.
    public private(set) var boundKidID: UUID?

    /// Governs only under the account it enrolled with; a mismatch locks the device.
    public private(set) var enrolledAccountRecordName: String?

    /// Which grown-up set it up. For the roster, not for permission.
    public private(set) var enrolledByGrownUpID: UUID?

    public private(set) var enrolledAt: Date = Date.distantPast

    /// Drives "last heard 4 min ago" — an honest way to show a deny hasn't landed.
    public private(set) var lastSeenAt: Date = Date.distantPast

    /// The one row that must not delete — deleting would silently un-revoke it.
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

    /// Unreadable role fails closed: not-a-player, like the rest of this store.
    public var role: DeviceRole? { DeviceRole(rawValue: roleRaw) }

    public var platform: DevicePlatform? { DevicePlatform(rawValue: platformRaw) }

    /// Whether this device may still open anything.
    public var isRevoked: Bool { revokedAt != nil }

    // MARK: - Writing

    public func rename(to newLabel: String, at: Date = .now) {
        label = newLabel
        modifiedAt = at
    }

    /// Enrollment must refuse binding a kid until that device already has a passcode.
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

// MARK: - Absorbing a record another device wrote

extension DeviceRecord {
    func applySync(
        familyID: UUID?,
        label: String,
        roleRaw: String?,
        platformRaw: String?,
        boundKidID: UUID?,
        enrolledAccountRecordName: String?,
        enrolledByGrownUpID: UUID?,
        enrolledAt: Date?,
        lastSeenAt: Date?,
        revokedAt: Date?,
        at: Date
    ) {
        if let familyID, self.familyID == nil { self.familyID = familyID }
        self.label = label
        if let roleRaw { self.roleRaw = roleRaw }
        if let platformRaw { self.platformRaw = platformRaw }
        self.boundKidID = boundKidID
        if let enrolledAccountRecordName { self.enrolledAccountRecordName = enrolledAccountRecordName }
        if let enrolledByGrownUpID, self.enrolledByGrownUpID == nil {
            self.enrolledByGrownUpID = enrolledByGrownUpID
        }
        if let enrolledAt { self.enrolledAt = min(self.enrolledAt, enrolledAt) }
        if let lastSeenAt { self.lastSeenAt = max(self.lastSeenAt, lastSeenAt) }

        // Sticky: earliest revocation wins, so a late sync can't un-revoke a device.
        if let revokedAt {
            self.revokedAt = min(self.revokedAt ?? .distantFuture, revokedAt)
        }
        modifiedAt = at
    }
}
