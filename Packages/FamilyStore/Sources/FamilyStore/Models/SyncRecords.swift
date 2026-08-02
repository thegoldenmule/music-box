import Foundation
import SwiftData

// Four records that exist so a second adult and a second device are possible.
// None of them has a row today, which is exactly why they are cheap to add now:
// a new entity migrates lightweight, and every one of these becomes a custom
// migration once a household's data is spread across two Apple Accounts.

/// The family's admin passcode, as something a device can *check against*
/// rather than something each device independently owns.
///
/// **The hole this closes.** `isPasscodeSet` reads the local Keychain and
/// nothing else, so a device holding the whole family zone with no local item —
/// a second parent's phone, a restored device, a child's iPad — shows *"Choose
/// an admin passcode"*, and `setPasscode` guards on that and nothing else. It
/// would have succeeded, over the family's entire policy set and every child's
/// search history.
///
/// So: *enter* on a device that has family data and no local item, and *choose*
/// only when no epoch exists anywhere.
///
/// **The epoch is also the first revocation path this app has ever had.**
/// `PasscodeStore.clear()` has no caller, and `setPasscode` refuses outright
/// once one is set — losing the passcode is currently a dead end. Rotation is
/// writing epoch n+1, which every device notices because its local item is
/// stamped with the epoch it satisfied.
///
/// **Household zone only.** It must never be replicated into a kid's zone: a
/// four-digit verifier is brute-forceable the moment it is readable, and handing
/// it to the device most likely to be lost or handed on is the trade running the
/// wrong way. A child's device checks the code a person types against its own
/// local item, and gets a new one when an adult sets it up.
///
/// The key derivation is **not decided yet** and must be before this is written
/// to for real. The local record's single salted SHA-256 is the wrong work
/// factor for a value that sits in iCloud, and CryptoKit offers HKDF but no
/// PBKDF2 at this floor.
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

/// A parent said "delete this child's history", as a **fact with a timestamp**
/// rather than as an absence.
///
/// **Deleting is currently an absence that has to win a race**, and under two
/// devices it loses. A device offline for a week imports the deletions and then
/// exports the rows it wrote while offline, which land *after* them. Worse,
/// `RecentsProjector.trail(for:)` is documented as always recomputed and saves
/// unconditionally on every launch — so the lagging device rebuilds the shelf
/// from its still-present visits and writes it back. The parent was told the
/// data was gone and their child's home screen is listing what they were doing.
///
/// A watermark fixes all of that at once, because it is a statement about a
/// *range* rather than about rows: everything at or below `clearedThrough` is
/// deleted whenever it turns up, and rows beneath it are refused on export. That
/// makes it idempotent, independent of arrival order, and effective against rows
/// that had not been written yet when it was issued.
///
/// Applying it needs a device-local watermark alongside — the last one this
/// device has acted on — which stays out of this store for the usual reason.
@Model
public final class HistoryClearRecord {
    public private(set) var id: UUID = UUID()

    /// Whose history. A plain identifier, not a relationship — see
    /// ``DeviceRecord``.
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

/// What an adult agreed to, with an account and a timestamp.
///
/// App Review guideline 5.1.4 states in as many words that a Kids-Category
/// parental gate *"is generally not the same as securing parental consent to
/// collect personal data"*, and its trigger is the **capability to share** a
/// minor's personal information — which the family share creates regardless of
/// who ends up holding the bytes. If review asks what consent was recorded, the
/// answer has to be a row, not a screenshot of a screen.
///
/// Two scopes, because they are two different asks and the second is larger:
/// sharing a household with another adult, and making a child's own Apple
/// Account a participant.
@Model
public final class ConsentRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var familyID: UUID?

    public private(set) var grownUpID: UUID?

    /// The account that agreed, opaque record name only.
    public private(set) var accountRecordName: String?

    /// ``ConsentScope/rawValue``, read defensively like every other enum here.
    public private(set) var scopeRaw: String = ConsentScope.shareHousehold.rawValue

    /// Which children the agreement covers, as identifiers. Stored rather than
    /// derived: the roster changes, and consent is a statement about the moment
    /// it was given.
    public private(set) var kidIDs: [UUID] = []

    public private(set) var agreedAt: Date = Date.distantPast

    /// Which build put the words in front of them. The wording will change and
    /// a record of agreement to unknown wording is not much of a record.
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
    /// Another adult will see everything this app records about every child in
    /// this family.
    case shareHousehold
    /// A child's own Apple Account becomes a participant in their zone.
    case childAccountParticipates
}

/// A batch of one kid's activity, packed for one device and one day.
///
/// **Events are the great majority of this store's write volume and have no
/// second reader as rows.** Sending them individually would put a parent's deny
/// behind a backlog of a child's blocked search results, and there is no way to
/// reorder a pending sync queue. So they travel as segments: opaque, batched,
/// and keyed by the device that wrote them.
///
/// The key is the design. `(kid, device, day, table, index)` means **two devices
/// never write the same segment**, so the volume leader in this store has no
/// conflict surface at all — not "rarely conflicts", none, by construction. That
/// property is only as good as `deviceID` is stable, which is worth stating
/// plainly: a Keychain identity that churns re-keys future segments and can
/// re-export a device's history under a new key. It is a duplicate, not a loss.
///
/// `payload` is deliberately opaque for the reason ``WeeklySummaryRecord``'s is,
/// and held outside the row for the same ceiling.
@Model
public final class ActivitySegmentRecord {
    public private(set) var id: UUID = UUID()

    public private(set) var kidID: UUID?
    public private(set) var deviceID: UUID?

    /// `yyyy-MM-dd`, UTC. A string rather than a `Date` because it is a bucket
    /// key that has to be identical on two devices in two time zones, and a
    /// `Date` invites someone to compare it with `<`.
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
