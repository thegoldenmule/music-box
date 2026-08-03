import CloudKit
import Foundation

/// One person on a share, as the admin needs to show them.
public struct ShareParticipantSummary: Sendable, Equatable, Identifiable {
    /// The opaque user record name, which is the only identifier this app keeps.
    public let id: String
    /// Whether they have actually joined, or are still an outstanding invite.
    public let hasAccepted: Bool
    public let permission: SharePermission
    /// Whether this is the person who created the share.
    public let isOwner: Bool

    public init(id: String, hasAccepted: Bool, permission: SharePermission, isOwner: Bool) {
        self.id = id
        self.hasAccepted = hasAccepted
        self.permission = permission
        self.isOwner = isOwner
    }
}

/// Sending and accepting invitations.
///
/// **A protocol because everything above it has to be reachable without a
/// network, an entitlement or an account** — the same seam `CatalogSource` puts
/// around MusicKit, and for the same reason. The admin screen, the roster and
/// the error copy are all testable against the stub; only the implementation
/// below the line needs a device to prove.
///
/// There is deliberately no fallback path. See ``FamilyZone`` — hierarchy
/// sharing was considered and rejected, because it needs parent references and
/// those collapse the zone topology that keeps a child out of their own policy.
public protocol FamilySharing: Sendable {
    /// Whether this device owns the household or joined somebody else's.
    ///
    /// **Everything else on this protocol depends on the answer**, and half of
    /// it is refused outright on a joined device — see ``HouseholdSide``. The
    /// admin screen asks first so it can draw the right screen rather than
    /// offering buttons that throw.
    func side() async throws -> HouseholdSide

    /// Makes sure every zone exists and is shared, and returns the link to send.
    ///
    /// The link is for the role's **anchor** zone — see ``SharePlan/anchor(for:)``.
    /// A link carries one share and a household has more than one zone, so
    /// every invitation is an anchor plus a second step.
    func invitation(for role: ShareRole, kids: [UUID]) async throws -> URL

    /// The second step: puts everyone who has joined onto the zones the anchor
    /// did not cover. Returns how many participants were changed.
    ///
    /// **Idempotent and safe to run repeatedly**, because there is no moment
    /// anything can hook to know when somebody accepted. A share does not call
    /// back; the owner's device finds out by looking. So this runs whenever the
    /// admin screen is opened rather than once, and doing nothing is the normal
    /// outcome.
    @discardableResult
    func reconcileGrants(for role: ShareRole, kids: [UUID]) async throws -> Int

    /// Accepts an invitation from a link somebody pasted or tapped.
    func accept(url: URL) async throws

    /// Accepts an invitation the system handed us, from a tapped link.
    func accept(metadata: CKShare.Metadata) async throws

    /// Everyone on the household share, joined or merely invited.
    func participants() async throws -> [ShareParticipantSummary]

    /// Takes somebody off every share.
    ///
    /// **Their device keeps whatever it last synced.** There is no remote wipe
    /// in CloudKit, so removing a participant stops them receiving anything new
    /// and does not reach back for what they already have. The confirmation copy
    /// has to say so rather than implying an undo.
    func removeParticipant(_ participantID: String) async throws
}

// MARK: -

/// The real one.
///
/// **Nothing here is verified.** It compiles against the SDK and has never run
/// against two accounts; the participant-write question is the open probe this
/// whole design rests on. Every method is written to fail loudly rather than
/// half-succeed, because a partially-shared household — the co-parent holding
/// the roster but not the child's policy — looks like sync being slow.
public struct CloudKitSharing: FamilySharing {
    private let container: CKContainer
    private let sides: HouseholdSideProvider

    public init(
        containerIdentifier: String = "iCloud.com.thegoldenmule.auralsanbox",
        sides: HouseholdSideProvider? = nil
    ) {
        container = CKContainer(identifier: containerIdentifier)
        self.sides = sides ?? HouseholdSideProvider(containerIdentifier: containerIdentifier)
    }

    /// The database this household's zones are in for this device.
    private var db: CKDatabase { container.privateCloudDatabase }

    public func side() async throws -> HouseholdSide {
        try await sides.current().side
    }

    /// Refuses everything an owner does on a device that joined.
    ///
    /// **Not a UI courtesy — the alternative is silent corruption.** Every
    /// owner-side method here writes to the *private* database, so on a joined
    /// device `ensureShare` would find no household share, create one, and
    /// leave an empty second household with this device as its owner. Nothing
    /// would report it: the screen would show a valid invitation link to a
    /// family containing nobody.
    private func requireOwner() async throws {
        guard try await side().ownsTheHousehold else { throw SharingFailure.notTheOwner }
    }

    public func invitation(for role: ShareRole, kids: [UUID]) async throws -> URL {
        try await requireOwner()

        // Every zone first. A share can only be attached to a zone that exists,
        // and a household half-created is one a co-parent joins into gaps.
        for zone in SharePlan.zones(kids: kids) {
            _ = try? await db.save(CKRecordZone(zoneID: HouseholdSide.owner.zoneID(for: zone)))
        }
        // And a share on each, so the second step has something to add to.
        for grant in SharePlan.grants(for: role, kids: kids) {
            _ = try await ensureShare(for: grant.zone)
        }

        let share = try await ensureShare(for: SharePlan.anchor(for: role))
        guard let url = share.url else { throw SharingFailure.shareHasNoURL }
        return url
    }

    public func reconcileGrants(for role: ShareRole, kids: [UUID]) async throws -> Int {
        // Not an error, because the admin screen runs this on every refresh and
        // a joined device opening it is entirely ordinary. There is simply
        // nothing to reconcile: the grants are the owner's to give.
        guard try await side().ownsTheHousehold else { return 0 }

        let anchor = try await ensureShare(for: SharePlan.anchor(for: role))
        let joiners = anchor.participants.filter {
            $0.role != .owner && $0.acceptanceStatus == .accepted
        }
        guard !joiners.isEmpty else { return 0 }

        let userIDs = joiners.compactMap(\.userIdentity.userRecordID)
        // **Looked up rather than reused.** A `CKShare.Participant` belongs to
        // the share it came from; adding that object to another share is not
        // the supported move. The identity is what carries across.
        let resolved = try await container.shareParticipants(forUserRecordIDs: userIDs)

        var changed = 0
        for grant in SharePlan.grantsAfterAnchor(for: role, kids: kids) {
            let share = try await ensureShare(for: grant.zone)
            var dirty = false

            for userID in userIDs {
                let name = userID.recordName
                if share.participants.contains(where: {
                    $0.userIdentity.userRecordID?.recordName == name
                }) { continue }
                guard case .success(let participant)? = resolved[userID] else { continue }
                participant.permission = grant.permission.ck
                share.addParticipant(participant)
                dirty = true
                changed += 1
            }

            if dirty { _ = try await db.save(share) }
        }
        return changed
    }

    public func accept(url: URL) async throws {
        let metadata = try await container.shareMetadata(for: url)
        try await accept(metadata: metadata)
    }

    public func accept(metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
        // The one moment a device's side is known to have changed. Without this
        // the cached `.owner` survives until relaunch, and every write in
        // between goes to the wrong database.
        await sides.invalidate()
    }

    /// Everyone on the household share, from whichever side this device is on.
    ///
    /// **Read-only on a joined device, and that is the whole difference.** The
    /// owner's version creates the share if it is missing; a joiner asking the
    /// same question must not, because "missing" there means *not shared with
    /// me* and creating one would answer it by inventing a household.
    public func participants() async throws -> [ShareParticipantSummary] {
        let share: CKShare?
        switch try await side() {
        case .owner: share = try await ensureShare(for: .household)
        case .joined(let owner): share = try await joinedShare(for: .household, owner: owner)
        }
        return (share?.participants ?? []).compactMap(Self.summary)
    }

    public func removeParticipant(_ participantID: String) async throws {
        try await requireOwner()

        for zone in try await sharedZones() {
            let share = try await ensureShare(for: zone)
            guard
                let participant = share.participants.first(where: {
                    $0.userIdentity.userRecordID?.recordName == participantID
                })
            else { continue }
            share.removeParticipant(participant)
            _ = try await db.save(share)
        }
    }

    // MARK: -

    /// The zone's share, created if it is not there yet.
    ///
    /// **`publicPermission` is left at `.none` deliberately.** Apple's own
    /// sample sets it to `.readWrite`, which means anyone holding the link can
    /// write. For a store holding a child's search history that is the wrong
    /// default — a link forwarded once would hand a stranger write access.
    /// Participants are added explicitly; the link is not the credential.
    /// **Owner-side only**, because it creates. Every caller must have passed
    /// `requireOwner()` first.
    private func ensureShare(for zone: FamilyZone) async throws -> CKShare {
        let zoneID = HouseholdSide.owner.zoneID(for: zone)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await db.record(for: shareID) as? CKShare { return existing }

        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Music Box" as CKRecordValue
        share.publicPermission = .none
        guard let saved = try await db.save(share) as? CKShare else {
            throw SharingFailure.shareHasNoURL
        }
        return saved
    }

    /// The share as a participant sees it: in the shared database, owned by
    /// somebody else, and `nil` rather than created when it is not there.
    private func joinedShare(for zone: FamilyZone, owner: String) async throws -> CKShare? {
        let zoneID = HouseholdSide.joined(ownerName: owner).zoneID(for: zone)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        return try? await container.sharedCloudDatabase.record(for: shareID) as? CKShare
    }

    private func sharedZones() async throws -> [FamilyZone] {
        try await db.allRecordZones().compactMap { FamilyZone(zoneName: $0.zoneID.zoneName) }
    }

    static func summary(_ participant: CKShare.Participant) -> ShareParticipantSummary? {
        guard let name = participant.userIdentity.userRecordID?.recordName else { return nil }
        return ShareParticipantSummary(
            id: name,
            hasAccepted: participant.acceptanceStatus == .accepted,
            permission: participant.permission == .readOnly ? .readOnly : .readWrite,
            isOwner: participant.role == .owner
        )
    }
}

public enum SharingFailure: Error, LocalizedError, Equatable {
    case noHouseholdZone
    case shareHasNoURL
    case participantNotFound(String)

    /// An owner-side action attempted on a device that joined somebody else's
    /// household. Inviting and removing belong to whoever set the family up.
    case notTheOwner

    public var errorDescription: String? {
        switch self {
        case .noHouseholdZone:
            "This device has no household to share yet."
        case .shareHasNoURL:
            "iCloud did not return an invitation link. Try again in a moment."
        case .participantNotFound:
            "That person has not accepted the invitation yet."
        case .notTheOwner:
            "This device joined a family that somebody else set up, so it can't invite or remove people. Ask whoever set it up."
        }
    }
}

// MARK: -

/// For previews, for tests, and for a build with no account.
public final class StubSharing: FamilySharing, @unchecked Sendable {
    private let lock = NSLock()
    private var joined: [ShareParticipantSummary]
    private var currentSide: HouseholdSide
    public private(set) var accepted: [URL] = []
    public private(set) var granted: [String: [ZoneGrant]] = [:]
    public private(set) var anchored: FamilyZone?

    public init(
        participants: [ShareParticipantSummary] = [],
        side: HouseholdSide = .owner
    ) {
        joined = participants
        currentSide = side
    }

    public func side() async throws -> HouseholdSide {
        lock.withLock { currentSide }
    }

    public func invitation(for role: ShareRole, kids: [UUID]) async throws -> URL {
        try lock.withLock {
            guard currentSide.ownsTheHousehold else { throw SharingFailure.notTheOwner }
            anchored = SharePlan.anchor(for: role)
        }
        return URL(string: "https://www.icloud.com/share/stub")!
    }

    @discardableResult
    public func reconcileGrants(for role: ShareRole, kids: [UUID]) async throws -> Int {
        let outstanding = SharePlan.grantsAfterAnchor(for: role, kids: kids)
        return lock.withLock {
            guard currentSide.ownsTheHousehold else { return 0 }
            let joiners = joined.filter { !$0.isOwner }
            for joiner in joiners { granted[joiner.id] = outstanding }
            return joiners.isEmpty ? 0 : outstanding.count * joiners.count
        }
    }

    public func accept(url: URL) async throws {
        lock.withLock {
            accepted.append(url)
            // Accepting is what makes a device a joiner, which is the state
            // change the real implementation invalidates its cache for.
            currentSide = .joined(ownerName: "_stubOwner")
        }
    }

    public func accept(metadata: CKShare.Metadata) async throws {
        lock.withLock { currentSide = .joined(ownerName: "_stubOwner") }
    }

    public func participants() async throws -> [ShareParticipantSummary] {
        lock.withLock { joined }
    }

    public func removeParticipant(_ participantID: String) async throws {
        try lock.withLock {
            guard currentSide.ownsTheHousehold else { throw SharingFailure.notTheOwner }
            joined.removeAll { $0.id == participantID }
        }
    }
}
