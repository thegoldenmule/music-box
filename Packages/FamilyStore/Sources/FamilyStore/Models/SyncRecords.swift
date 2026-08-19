import Foundation
import SwiftData

// Four records for a second adult and device — empty now, so cheap to add today.

/// A device *checks against* this rather than owning the passcode itself.
///
/// **The hole this closes.** `isPasscodeSet` reads only the local Keychain, so
/// a device with the family zone but no local item — a second parent's phone,
/// a restored device — shows "Choose a passcode" and `setPasscode` would have
/// succeeded, over the family's whole policy set and every child's history.
///
/// **First revocation path this app has had.** `PasscodeStore.clear()` has no
/// caller and `setPasscode` refuses once one is set — losing it is a dead end
/// today. Rotation writes epoch n+1; a device notices via its stamped epoch.
///
/// **Household zone only, never a kid's** — a brute-forceable four-digit
/// verifier does not belong on the device most likely to be lost or handed on.
///
/// **Key derivation is not decided.** Salted SHA-256 is the wrong work factor
/// for iCloud, and CryptoKit has HKDF but no PBKDF2 at this floor.
@Model
public final class PasscodeEpochRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var familyID: UUID?

    /// Monotonic. A device whose local item names an older epoch re-prompts.
    public private(set) var epoch: Int = 0

    public private(set) var salt: Data = Data()

    /// The derived value, never the passcode.
    public private(set) var verifier: Data = Data()

    public private(set) var setByGrownUpID: UUID?
    public private(set) var setAt: Date = Date.distantPast
    public private(set) var modifiedAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        familyID: UUID? = nil,
        epoch: Int,
        salt: Data,
        verifier: Data,
        setByGrownUpID: UUID? = nil,
        at: Date = .now
    ) {
        self.id = id
        self.familyID = familyID
        self.epoch = epoch
        self.salt = salt
        self.verifier = verifier
        self.setByGrownUpID = setByGrownUpID
        self.setAt = at
        self.modifiedAt = at
    }
}

/// A watermark, not a per-row absence — an absence loses the race to a lagger.
@Model
public final class HistoryClearRecord {
    public private(set) var id: UUID = UUID()

    /// A plain identifier, not a relationship — see `DeviceRecord`.
    public private(set) var kidID: UUID?

    /// Everything at or before this instant is to be destroyed.
    public private(set) var clearedThrough: Date = Date.distantPast

    public private(set) var issuedAt: Date = Date.distantPast
    public private(set) var issuedByGrownUpID: UUID?
    public private(set) var modifiedAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        kidID: UUID?,
        clearedThrough: Date,
        issuedByGrownUpID: UUID? = nil,
        at: Date = .now
    ) {
        self.id = id
        self.kidID = kidID
        self.clearedThrough = clearedThrough
        self.issuedByGrownUpID = issuedByGrownUpID
        self.issuedAt = at
        self.modifiedAt = at
    }
}

/// A row, not a screenshot — 5.1.4's trigger is the capability to share.
@Model
public final class ConsentRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var familyID: UUID?

    public private(set) var grownUpID: UUID?

    /// The account that agreed, opaque record name only.
    public private(set) var accountRecordName: String?

    /// ``ConsentScope/rawValue``, read defensively like every other enum here.
    public private(set) var scopeRaw: String = ConsentScope.shareHousehold.rawValue

    /// Stored, not derived — the roster changes; consent is about the moment given.
    public private(set) var kidIDs: [UUID] = []

    public private(set) var agreedAt: Date = Date.distantPast

    /// The wording will change — agreement to unknown wording isn't much of a record.
    public private(set) var appVersion: String = ""

    public private(set) var modifiedAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        familyID: UUID? = nil,
        grownUpID: UUID? = nil,
        accountRecordName: String? = nil,
        scope: ConsentScope,
        kidIDs: [UUID],
        appVersion: String,
        at: Date = .now
    ) {
        self.id = id
        self.familyID = familyID
        self.grownUpID = grownUpID
        self.accountRecordName = accountRecordName
        self.scopeRaw = scope.rawValue
        self.kidIDs = kidIDs
        self.appVersion = appVersion
        self.agreedAt = at
        self.modifiedAt = at
    }

    public var scope: ConsentScope? { ConsentScope(rawValue: scopeRaw) }
}

/// What an adult was asked to agree to.
public enum ConsentScope: String, Sendable, CaseIterable {
    /// Another adult sees everything this app records about every child here.
    case shareHousehold
    /// A child's own Apple Account becomes a participant in their zone.
    case childAccountParticipates
}

/// Keyed by kid/device/day/table/index — no conflict surface, by construction.
@Model
public final class ActivitySegmentRecord {
    public private(set) var id: UUID = UUID()

    public private(set) var kidID: UUID?
    public private(set) var deviceID: UUID?

    /// A string, not a `Date` — a bucket key must match across time zones exactly.
    public private(set) var dayUTC: String = ""

    /// Which event table this batch came from.
    public private(set) var table: String = ""

    /// Position within the day, so one busy day can span several segments.
    public private(set) var index: Int = 0

    @Attribute(.externalStorage)
    public private(set) var payload: Data = Data()

    public private(set) var modifiedAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        kidID: UUID?,
        deviceID: UUID?,
        dayUTC: String,
        table: String,
        index: Int,
        payload: Data,
        at: Date = .now
    ) {
        self.id = id
        self.kidID = kidID
        self.deviceID = deviceID
        self.dayUTC = dayUTC
        self.table = table
        self.index = index
        self.payload = payload
        self.modifiedAt = at
    }
}
