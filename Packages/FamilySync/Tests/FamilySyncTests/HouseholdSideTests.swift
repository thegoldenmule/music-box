import CloudKit
import Foundation
import Testing

@testable import FamilySync

private let ada = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!
private let theirs = "_ac1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d"
private let alsoTheirs = "_ff00112233445566778899aabbccddee"

@Suite("Which side of the share this device is on")
struct HouseholdSideResolution {
    /// The ordinary first launch: nothing has been shared with this account, so
    /// it owns whatever household it has.
    @Test("No shared zones means this device owns the household")
    func nothingSharedMeansOwner() {
        #expect(HouseholdSide.resolve(sharedZones: []).side == .owner)
    }

    @Test("A household zone in the shared database means this device joined")
    func aSharedHouseholdMeansJoined() {
        let resolved = HouseholdSide.resolve(sharedZones: [
            RemoteZone(name: "household", ownerName: theirs)
        ])

        #expect(resolved.side == .joined(ownerName: theirs))
        #expect(resolved.ambiguousOwners.isEmpty)
    }

    /// A child's device is never given the household zone — only their own two —
    /// so the rule cannot key off the household zone specifically.
    @Test("A child's device joined even though it has no household zone")
    func aChildDeviceIsAlsoAJoiner() {
        let resolved = HouseholdSide.resolve(sharedZones: [
            RemoteZone(name: "kid-\(ada.uuidString.lowercased())-work", ownerName: theirs),
            RemoteZone(name: "kid-\(ada.uuidString.lowercased())-policy", ownerName: theirs),
        ])

        #expect(resolved.side == .joined(ownerName: theirs))
    }

    /// Somebody else's shared photo album is in the same database. Only zones
    /// this app recognises count.
    @Test("A shared zone belonging to another app is not evidence")
    func foreignZonesAreIgnored() {
        let resolved = HouseholdSide.resolve(sharedZones: [
            RemoteZone(name: "com.example.Notes.SharedNotes", ownerName: theirs)
        ])

        #expect(resolved.side == .owner)
    }

    /// **The refusal, and the reason it is a refusal.** Two households in the
    /// shared database has no correct answer, and the two ways of being wrong
    /// are not equal: staying on the owner side makes an invitation look like it
    /// did not take, which somebody can see and fix. Picking one writes a
    /// child's data into a stranger's store, which nobody can take back.
    @Test("Two families is refused rather than guessed at")
    func twoFamiliesStaysPut() {
        let resolved = HouseholdSide.resolve(sharedZones: [
            RemoteZone(name: "household", ownerName: theirs),
            RemoteZone(name: "household", ownerName: alsoTheirs),
        ])

        #expect(resolved.side == .owner)
        #expect(resolved.ambiguousOwners == [alsoTheirs, theirs].sorted())
    }

    /// One owner across several zones is the normal co-parent case, not an
    /// ambiguity — otherwise every real invitation would trip the refusal.
    @Test("One owner across five zones is not ambiguous")
    func oneOwnerManyZonesIsFine() {
        let names = ["household"]
            + [ada].flatMap {
                ["kid-\($0.uuidString.lowercased())-policy", "kid-\($0.uuidString.lowercased())-work"]
            }
        let resolved = HouseholdSide.resolve(
            sharedZones: names.map { RemoteZone(name: $0, ownerName: theirs) })

        #expect(resolved.side == .joined(ownerName: theirs))
        #expect(resolved.ambiguousOwners.isEmpty)
    }
}

// MARK: -

@Suite("A zone ID says whose zone it is")
struct ZoneOwnership {
    /// **The bug this whole type exists for.** The owner and the joiner name the
    /// same logical zone, and the IDs must differ — a joiner using the owner's
    /// form is asking CloudKit for a zone it claims to own, which CloudKit
    /// answers by creating an empty one.
    @Test("The same zone has a different ID on each side")
    func theSameZoneIsNotTheSameID() {
        let owner = HouseholdSide.owner.zoneID(for: .household)
        let joiner = HouseholdSide.joined(ownerName: theirs).zoneID(for: .household)

        #expect(owner.zoneName == joiner.zoneName)
        #expect(owner != joiner)
        #expect(owner.ownerName == CKCurrentUserDefaultName)
        #expect(joiner.ownerName == theirs)
    }

    /// Whichever side produced it, the zone name still parses back — that is
    /// what lets an arriving record say where it came from.
    @Test("A zone survives the trip through an ID on either side")
    func zonesRoundTripFromEitherSide() {
        let zones: [FamilyZone] = [.household, .kidPolicy(ada), .kidWork(ada)]
        for side in [HouseholdSide.owner, .joined(ownerName: theirs)] {
            for zone in zones {
                #expect(FamilyZone(zoneName: side.zoneID(for: zone).zoneName) == zone)
            }
        }
    }

    @Test("The side says which database to look in")
    func scopeFollowsTheSide() {
        #expect(HouseholdSide.owner.databaseScope == .private)
        #expect(HouseholdSide.joined(ownerName: theirs).databaseScope == .shared)
    }
}

// MARK: -

@Suite("What a joined device is not allowed to do")
struct JoinedDeviceRefusals {
    /// Inviting is the owner's to do. On a joined device the same call would
    /// write to the private database, mint a second empty household, and hand
    /// back a link to a family containing nobody.
    @Test("A joined device cannot issue an invitation")
    func joinedCannotInvite() async throws {
        let stub = StubSharing(side: .joined(ownerName: theirs))

        await #expect(throws: SharingFailure.notTheOwner) {
            _ = try await stub.invitation(for: .coParent, kids: [ada])
        }
    }

    @Test("A joined device cannot remove anybody")
    func joinedCannotRemove() async throws {
        let stub = StubSharing(
            participants: [
                ShareParticipantSummary(
                    id: "_them", hasAccepted: true, permission: .readWrite, isOwner: true)
            ],
            side: .joined(ownerName: theirs))

        await #expect(throws: SharingFailure.notTheOwner) {
            try await stub.removeParticipant("_them")
        }
    }

    /// **Not an error, deliberately.** The admin screen reconciles on every
    /// refresh and a joined device opening it is ordinary. There is nothing to
    /// do, so it does nothing rather than showing an alert.
    @Test("Reconciling on a joined device is a quiet no-op")
    func joinedReconcileIsSilent() async throws {
        let stub = StubSharing(
            participants: [
                ShareParticipantSummary(
                    id: "_them", hasAccepted: true, permission: .readWrite, isOwner: false)
            ],
            side: .joined(ownerName: theirs))

        #expect(try await stub.reconcileGrants(for: .coParent, kids: [ada]) == 0)
        #expect(stub.granted.isEmpty)
    }

    /// Accepting is the moment a device stops being an owner, and the side has
    /// to change with it rather than at the next launch — every write in
    /// between would otherwise go to the wrong database.
    @Test("Accepting makes this device a joiner immediately")
    func acceptingFlipsTheSide() async throws {
        let stub = StubSharing()
        #expect(try await stub.side() == .owner)

        try await stub.accept(url: URL(string: "https://www.icloud.com/share/x")!)

        #expect(try await stub.side().ownsTheHousehold == false)
    }
}
