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
    /// Makes sure every zone exists and is shared, and returns the link to send.
    ///
    /// The link is for the **household** zone. The other zones are shared too,
    /// but a link carries one share, so joining the rest happens by the owner
    /// adding the participant once they have an identity to add.
    func invitationURL(zones: [FamilyZone]) async throws -> URL

    /// Accepts an invitation from a link somebody pasted or tapped.
    func accept(url: URL) async throws

    /// Accepts an invitation the system handed us, from a tapped link.
    func accept(metadata: CKShare.Metadata) async throws

    /// Everyone on the household share, joined or merely invited.
    func participants() async throws -> [ShareParticipantSummary]

    /// Grants an already-known participant the rest of the zones they need.
    ///
    /// The second half of the invite: a link carries one share, so a co-parent
    /// arrives holding the household and nothing else until this runs.
    func grant(_ grants: [ZoneGrant], to participantID: String) async throws

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

    public init(containerIdentifier: String = "iCloud.com.thegoldenmule.auralsanbox") {
        container = CKContainer(identifier: containerIdentifier)
    }

    private var db: CKDatabase { container.privateCloudDatabase }

    public func invitationURL(zones: [FamilyZone]) async throws -> URL {
        guard let household = zones.first(where: { $0 == .household }) else {
            throw SharingFailure.noHouseholdZone
        }

        // Every zone first. A share can only be attached to a zone that exists,
        // and a household half-created is one a co-parent joins into gaps.
        for zone in zones {
            _ = try? await db.save(CKRecordZone(zoneID: zone.id))
        }

        let share = try await ensureShare(for: household)
        guard let url = share.url else { throw SharingFailure.shareHasNoURL }
        return url
    }

    public func accept(url: URL) async throws {
        let metadata = try await container.shareMetadata(for: url)
        try await accept(metadata: metadata)
    }

    public func accept(metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
    }

    public func participants() async throws -> [ShareParticipantSummary] {
        let share = try await ensureShare(for: .household)
        return share.participants.compactMap(Self.summary)
    }

    public func grant(_ grants: [ZoneGrant], to participantID: String) async throws {
        for grant in grants where grant.zone != .household {
            let share = try await ensureShare(for: grant.zone)
            guard
                let participant = share.participants.first(where: {
                    $0.userIdentity.userRecordID?.recordName == participantID
                })
            else {
                // The participant is not on this share yet. Adding them needs
                // their identity, which only the household share can supply —
                // so this is the caller's ordering mistake rather than a
                // transient failure, and saying so beats retrying forever.
                throw SharingFailure.participantNotFound(participantID)
            }
            participant.permission = grant.permission.ck
            _ = try await db.save(share)
        }
    }

    public func removeParticipant(_ participantID: String) async throws {
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
    private func ensureShare(for zone: FamilyZone) async throws -> CKShare {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone.id)
        if let existing = try? await db.record(for: shareID) as? CKShare { return existing }

        let share = CKShare(recordZoneID: zone.id)
        share[CKShare.SystemFieldKey.title] = "Music Box" as CKRecordValue
        share.publicPermission = .none
        guard let saved = try await db.save(share) as? CKShare else {
            throw SharingFailure.shareHasNoURL
        }
        return saved
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

    public var errorDescription: String? {
        switch self {
        case .noHouseholdZone:
            "This device has no household to share yet."
        case .shareHasNoURL:
            "iCloud did not return an invitation link. Try again in a moment."
        case .participantNotFound:
            "That person has not accepted the invitation yet."
        }
    }
}

// MARK: -

/// For previews, for tests, and for a build with no account.
public final class StubSharing: FamilySharing, @unchecked Sendable {
    private let lock = NSLock()
    private var joined: [ShareParticipantSummary]
    public private(set) var accepted: [URL] = []
    public private(set) var granted: [String: [ZoneGrant]] = [:]

    public init(participants: [ShareParticipantSummary] = []) {
        joined = participants
    }

    public func invitationURL(zones: [FamilyZone]) async throws -> URL {
        URL(string: "https://www.icloud.com/share/stub")!
    }

    public func accept(url: URL) async throws {
        lock.withLock { accepted.append(url) }
    }

    public func accept(metadata: CKShare.Metadata) async throws {}

    public func participants() async throws -> [ShareParticipantSummary] {
        lock.withLock { joined }
    }

    public func grant(_ grants: [ZoneGrant], to participantID: String) async throws {
        lock.withLock { granted[participantID] = grants }
    }

    public func removeParticipant(_ participantID: String) async throws {
        lock.withLock { joined.removeAll { $0.id == participantID } }
    }
}
