import CloudKit
import Foundation

/// A zone as the server describes it, which is a name and whose it is.
///
/// A plain value rather than `CKRecordZone.ID` so the rule below can be tested
/// without a container — the same reason `BindingResolver` takes `AccountState`
/// instead of asking CloudKit itself.
public struct RemoteZone: Sendable, Equatable, Hashable {
    public let name: String
    public let ownerName: String

    public init(name: String, ownerName: String) {
        self.name = name
        self.ownerName = ownerName
    }

    public init(_ id: CKRecordZone.ID) {
        self.init(name: id.zoneName, ownerName: id.ownerName)
    }
}

// MARK: -

/// Which side of the share this device is on.
///
/// **The distinction the rest of the sync layer was missing, and it is not a
/// detail.** A household is a set of zones, and those zones are owned by
/// exactly one Apple Account. On the device that created them they sit in the
/// private database and `CKCurrentUserDefaultName` names their owner. On a
/// device that accepted an invitation the very same zones sit in the *shared*
/// database and are owned by somebody else — a different database, a different
/// owner name, and therefore a different `CKRecordZone.ID` for what is
/// logically the same zone.
///
/// Getting it wrong does not fail loudly. A joined device that assumes it is
/// the owner addresses writes to a zone it owns and CloudKit obliges by making
/// one: an empty household beside the real one, with this device as its owner,
/// syncing to nobody. That is the failure this type exists to prevent, and it
/// is silent in every direction — the roster looks right, the outbox drains,
/// and no record reaches the family.
public enum HouseholdSide: Sendable, Equatable, Hashable {
    /// This device created the household. The zones are its own.
    case owner

    /// This device accepted an invitation. The zones belong to `ownerName` and
    /// live in the shared database.
    case joined(ownerName: String)

    /// Who owns the zones, in the form `CKRecordZone.ID` wants.
    public var ownerName: String {
        switch self {
        case .owner: CKCurrentUserDefaultName
        case .joined(let name): name
        }
    }

    /// Which database the household's zones are in **for this device**.
    public var databaseScope: CKDatabase.Scope {
        switch self {
        case .owner: .private
        case .joined: .shared
        }
    }

    public var ownsTheHousehold: Bool {
        if case .owner = self { return true }
        return false
    }

    /// The record zone ID for one of this household's zones.
    ///
    /// **The only place an owner name is supplied.** `FamilyZone` deliberately
    /// has no zero-argument `id`, because the version that defaulted to
    /// `CKCurrentUserDefaultName` is exactly how the joined case went unnoticed
    /// — it compiled everywhere and was wrong on half the devices.
    public func zoneID(for zone: FamilyZone) -> CKRecordZone.ID {
        zone.id(ownedBy: ownerName)
    }
}

// MARK: -

/// What resolving the side found.
///
/// Two fields rather than one because "which side" and "is the answer
/// trustworthy" are separate questions, and a device in the ambiguous case
/// needs the admin screen to be able to say why.
public struct SideResolution: Sendable, Equatable {
    public let side: HouseholdSide

    /// The owners of every distinct household found in the shared database,
    /// when there is more than one. Empty in the ordinary case.
    public let ambiguousOwners: [String]

    public init(side: HouseholdSide, ambiguousOwners: [String] = []) {
        self.side = side
        self.ambiguousOwners = ambiguousOwners
    }
}

extension HouseholdSide {
    /// Which side this device is on, given what its shared database holds.
    ///
    /// **Only the shared side is evidence, and that asymmetry is the whole
    /// rule.** Private zones prove nothing: `SyncEngineHost.start` creates them
    /// eagerly on first launch, so every device has them whether or not it ever
    /// owned a household. A household zone in the *shared* database can only
    /// have arrived by this account explicitly accepting an invitation, so it
    /// is the one signal that means something.
    ///
    /// **Two different owners is refused rather than picked between.** A device
    /// that has joined two households has no correct answer available, and the
    /// two ways of being wrong are not equal: staying on the owner side makes
    /// an invitation look like it did not take, which is visible and
    /// recoverable, while guessing writes one family's child data into another
    /// family's store, which is not.
    public static func resolve(sharedZones: [RemoteZone]) -> SideResolution {
        let ours = sharedZones.filter { FamilyZone(zoneName: $0.name) != nil }
        let owners = Set(ours.map(\.ownerName)).sorted()

        switch owners.count {
        case 0: return SideResolution(side: .owner)
        case 1: return SideResolution(side: .joined(ownerName: owners[0]))
        default: return SideResolution(side: .owner, ambiguousOwners: owners)
        }
    }
}

// MARK: -

/// Resolves the side once and remembers it.
///
/// **An actor because two callers need the same answer and neither should ask
/// twice.** `SyncEngineHost` needs it before it can route a write and
/// `CloudKitSharing` needs it before it can decide whether this device may
/// issue an invitation at all; both at launch, both async.
///
/// The answer is cached rather than persisted. It costs one list-zones call per
/// launch, it is always current, and there is no stale copy to be wrong after a
/// reinstall or a sign-out — which matters because the stale value that would
/// hurt is precisely `.owner`.
public actor HouseholdSideProvider {
    private let container: CKContainer
    private var cached: SideResolution?

    public init(containerIdentifier: String = "iCloud.com.thegoldenmule.auralsanbox") {
        container = CKContainer(identifier: containerIdentifier)
    }

    /// The side, asking the server the first time and on demand after that.
    public func current(refreshing: Bool = false) async throws -> SideResolution {
        if !refreshing, let cached { return cached }

        let zones = try await container.sharedCloudDatabase.allRecordZones()
        let resolved = HouseholdSide.resolve(sharedZones: zones.map { RemoteZone($0.zoneID) })
        cached = resolved
        return resolved
    }

    /// Forgets the cached answer, for use straight after accepting a share —
    /// the one moment a device's side is known to have changed.
    public func invalidate() {
        cached = nil
    }
}
