import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import FamilyStore
@testable import FamilySync

private let ada = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!
private let sam = UUID(uuidString: "5A000000-0000-0000-0000-000000000005")!
private let kids = [ada, sam]

@Suite("Who an invitation lets in, and where")
struct SharePlanTests {
    /// A zone-wide share is per zone, so "invite the other parent" is not one
    /// grant. A household with two children is five.
    @Test("A co-parent gets the household and every child's zones")
    func coParentGetsEverything() {
        let grants = SharePlan.grants(for: .coParent, kids: kids)

        #expect(grants.count == 5)
        #expect(grants.contains(ZoneGrant(zone: .household, permission: .readWrite)))
        for kid in kids {
            #expect(grants.contains(ZoneGrant(zone: .kidPolicy(kid), permission: .readWrite)))
            #expect(grants.contains(ZoneGrant(zone: .kidWork(kid), permission: .readWrite)))
        }
    }

    /// **The guarantee the zone split exists for.** A child holding write on
    /// their own policy zone could edit the `PolicyEntryRecord`s that decide
    /// what they may reach — the deny their parent just added among them.
    @Test("A child can never write their own policy")
    func childCannotWriteTheirOwnPolicy() {
        let grants = SharePlan.grants(for: .child(ada), kids: kids)
        let policy = grants.first { $0.zone == .kidPolicy(ada) }

        #expect(policy?.permission == .readOnly)
    }

    /// The other half: what is theirs, they own.
    @Test("A child can write their own favorites and playlists")
    func childOwnsTheirWork() {
        let grants = SharePlan.grants(for: .child(ada), kids: kids)
        #expect(grants.contains(ZoneGrant(zone: .kidWork(ada), permission: .readWrite)))
    }

    /// **A sibling's zones are not on the list at all**, which is enforcement
    /// rather than the app declining to draw a screen. CloudKit has no
    /// per-record permissions, so this is the only place it can be enforced.
    @Test("A child gets nothing of a sibling's")
    func siblingsAreInvisible() {
        let grants = SharePlan.grants(for: .child(ada), kids: kids)
        let zones = grants.map(\.zone)

        #expect(zones.contains(.kidPolicy(sam)) == false)
        #expect(zones.contains(.kidWork(sam)) == false)
        #expect(grants.count == 2)
    }

    /// The household zone holds the roster, the device list, the consents and
    /// the passcode epoch. A child's device receives none of it — which is why
    /// those records live there and not beside the child's own.
    @Test("A child never gets the household zone")
    func childNeverGetsTheHousehold() {
        let grants = SharePlan.grants(for: .child(ada), kids: kids)
        #expect(grants.map(\.zone).contains(.household) == false)
    }

    /// A child who is not in this household is not a participant in it. Falling
    /// back to "their own zones" would mint a grant for a zone that does not
    /// belong to anybody here.
    @Test("A child who is not in the household gets nothing")
    func unknownChildGetsNothing() {
        #expect(SharePlan.grants(for: .child(UUID()), kids: kids).isEmpty)
    }

    @Test("A household with no children still shares itself")
    func childlessHousehold() {
        let grants = SharePlan.grants(for: .coParent, kids: [])
        #expect(grants == [ZoneGrant(zone: .household, permission: .readWrite)])
    }

    /// Every zone a grant can name has to be a zone the household actually
    /// creates, or the invitation points at nothing.
    @Test("Every granted zone is one the household owns")
    func grantsOnlyNameRealZones() {
        let owned = Set(SharePlan.zones(kids: kids))
        for role in [ShareRole.coParent, .child(ada), .child(sam)] {
            for grant in SharePlan.grants(for: role, kids: kids) {
                #expect(owned.contains(grant.zone), "\(grant.zone.zoneName)")
            }
        }
    }

    @Test("A household owns one zone plus two per child")
    func zoneCount() {
        #expect(SharePlan.zones(kids: kids).count == 5)
        #expect(SharePlan.zones(kids: []).count == 1)
    }
}

// MARK: -

@Suite("The sharing seam")
struct SharingSeam {
    /// The admin screen, the roster and the error copy all have to be reachable
    /// without an account — which is what the stub is for, and what makes the
    /// unverifiable part exactly the CloudKit implementation and nothing above
    /// it.
    /// **Two devices, because one cannot do both.** The original version of this
    /// test invited and then accepted on the same stub, which reads fine and
    /// describes a household that cannot exist: accepting is what makes a device
    /// a joiner, and a joiner has nothing to invite anyone to.
    @Test("A stub can stand in for the whole protocol, from the owner's side")
    func stubConformsAsOwner() async throws {
        let stub = StubSharing(participants: [
            ShareParticipantSummary(id: "_me", hasAccepted: true, permission: .readWrite, isOwner: true)
        ])

        #expect(try await stub.side() == .owner)
        _ = try await stub.invitation(for: .coParent, kids: kids)
        #expect(stub.anchored == .household)

        #expect(try await stub.participants().count == 1)
        try await stub.removeParticipant("_me")
        #expect(try await stub.participants().isEmpty)
    }

    @Test("And from the side that accepted")
    func stubConformsAsJoiner() async throws {
        let stub = StubSharing()
        let url = URL(string: "https://www.icloud.com/share/stub")!

        try await stub.accept(url: url)

        #expect(stub.accepted == [url])
        #expect(try await stub.side().ownsTheHousehold == false)
    }

    /// An invited-but-not-yet-joined participant is a state the roster has to be
    /// able to show. Without it a parent who sent an invitation has no way to
    /// tell "they have not tapped it yet" from "it did not work".
    @Test("A participant who has not accepted is distinguishable")
    func pendingIsVisible() async throws {
        let stub = StubSharing(participants: [
            ShareParticipantSummary(id: "_a", hasAccepted: true, permission: .readWrite, isOwner: true),
            ShareParticipantSummary(id: "_b", hasAccepted: false, permission: .readWrite, isOwner: false),
        ])

        let people = try await stub.participants()
        #expect(people.filter(\.hasAccepted).count == 1)
        #expect(people.filter { !$0.hasAccepted }.count == 1)
    }
}

// MARK: -

@Suite("Every record knows where it lives")
@MainActor
struct ZonePlacement {
    /// **The check that would have caught a bug the tests did not.** A record
    /// whose zone cannot be resolved is never sent, and nothing reports it —
    /// the outbox simply never drains. A playlist song reached the server only
    /// after `PlaylistEntryRecord` started carrying the kid it belongs to.
    ///
    /// So: every kid-scoped record an encoder produces must be placeable, and
    /// placeable in a zone the household actually owns.
    @Test("Every encoded record lands in a zone the household owns")
    func everyRecordIsPlaceable() throws {
        let context = ModelContext(try FamilyStore.inMemoryContainer())
        let family = Family(at: .now)
        let kid = Kid(name: "Ada", mode: .denyPlusAuto, at: .now)
        context.insert(family)
        context.insert(kid)
        family.addKid(kid, at: .now)

        kid.setMode(.allowOnly, at: .now)
        let entry = kid.addEntry(kind: .deny, id: CatalogID(.artist, "a"), displayName: "A")
        let favorite = try #require(kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B"))
        let playlist = kid.addPlaylist(named: "Car songs")
        let song = try #require(playlist.addSong(id: CatalogID(.song, "c"), displayName: "C"))
        let suggestion = kid.addSuggestion(
            target: .catalog(CatalogID(.album, "d")), displayName: "D")
        let suggested = try #require(
            suggestion.addSong(id: CatalogID(.song, "e"), displayName: "E"))

        let owned = Set(SharePlan.zones(kids: [kid.id]))
        let records: [SyncedRecord] = [
            family.record, kid.record, entry.record,
            try #require(kid.sandboxSettings.first).record,
            favorite.record, playlist.record, song.record,
            suggestion.record, suggested.record,
        ]

        for record in records {
            // The same rule the engine host uses: a `Kid`'s own id names the
            // kid, everything else has to carry one.
            let owner =
                record.type == Kid.syncRecordType
                ? record.uuid(Field.id) : record.uuid(Field.kidID)
            let zone = FamilyZone.placing(record.type, kidID: owner)

            let placed = try #require(zone, "\(record.type) could not be placed")
            #expect(owned.contains(placed), "\(record.type) → \(placed.zoneName), not owned")
        }
    }

    /// Household-scoped records have no kid and must still place.
    @Test("Household records place without a kid")
    func householdRecordsNeedNoKid() {
        let device = DeviceRecord(label: "iPad", role: .kidOnly, platform: .pad)
        #expect(FamilyZone.placing(device.record.type, kidID: nil) == .household)
    }
}


// MARK: -

@Suite("An invitation is an anchor plus a second step")
struct AnchorAndGrants {
    /// A link carries one share and a household has more than one zone, so the
    /// anchor is only ever part of an invitation.
    @Test("A co-parent's link anchors on the household")
    func coParentAnchorsOnHousehold() {
        #expect(SharePlan.anchor(for: .coParent) == .household)

        let rest = SharePlan.grantsAfterAnchor(for: .coParent, kids: kids)
        #expect(rest.count == 4)
        #expect(rest.contains { $0.zone == .household } == false)
    }

    /// **A child anchors on their work zone, and the choice is not arbitrary.**
    /// If the second step never runs, this leaves them able to keep their own
    /// favorites and unable to read their own rules — the harmless way round.
    /// Anchoring on policy would leave them holding the rules and unable to save
    /// anything they did.
    @Test("A child's link anchors on the half they may write")
    func childAnchorsOnWork() {
        #expect(SharePlan.anchor(for: .child(ada)) == .kidWork(ada))

        let rest = SharePlan.grantsAfterAnchor(for: .child(ada), kids: kids)
        #expect(rest == [ZoneGrant(zone: .kidPolicy(ada), permission: .readOnly)])
    }

    /// The one case where an invitation is complete on acceptance.
    @Test("A childless household needs no second step")
    func childlessNeedsNoSecondStep() {
        #expect(SharePlan.grantsAfterAnchor(for: .coParent, kids: []).isEmpty)
    }

    /// The anchor has to be a zone the role actually gets, or the link points at
    /// something they may not hold.
    @Test("Every anchor is a zone that role is granted")
    func anchorIsAlwaysGranted() {
        for role in [ShareRole.coParent, .child(ada), .child(sam)] {
            let zones = SharePlan.grants(for: role, kids: kids).map(\.zone)
            #expect(zones.contains(SharePlan.anchor(for: role)))
        }
    }

    /// Anchor plus remainder must be the whole grant, with nothing dropped
    /// between them — a missing zone is a co-parent whose data never arrives.
    @Test("Anchor plus the second step is the whole invitation")
    func nothingIsLostBetweenTheTwo() {
        for role in [ShareRole.coParent, .child(ada)] {
            let all = Set(SharePlan.grants(for: role, kids: kids).map(\.zone))
            let covered = Set(
                SharePlan.grantsAfterAnchor(for: role, kids: kids).map(\.zone)
            ).union([SharePlan.anchor(for: role)])
            #expect(all == covered)
        }
    }

    /// The second step runs on every launch and whenever the admin screen opens,
    /// because a share does not call back — so doing it twice has to be free.
    @Test("Reconciling twice is not different from reconciling once")
    func reconcileIsIdempotent() async throws {
        let stub = StubSharing(participants: [
            ShareParticipantSummary(id: "_me", hasAccepted: true, permission: .readWrite, isOwner: true),
            ShareParticipantSummary(id: "_them", hasAccepted: true, permission: .readWrite, isOwner: false),
        ])

        _ = try await stub.invitation(for: .coParent, kids: kids)
        _ = try await stub.reconcileGrants(for: .coParent, kids: kids)
        let after = stub.granted
        _ = try await stub.reconcileGrants(for: .coParent, kids: kids)

        #expect(stub.granted.keys.sorted() == after.keys.sorted())
        #expect(stub.granted["_them"]?.count == 4)
        // The owner is never granted anything — they already own it.
        #expect(stub.granted["_me"] == nil)
    }

    /// **Because this now runs on every launch, not only from the sharing
    /// screen.** Reconciliation used to create the anchor share it then read, so
    /// moving it to launch would have minted a `CKShare` on every zone of every
    /// household that has never invited anybody — making "this family is shared"
    /// a consequence of opening the app.
    @Test("A household nobody has invited into reconciles to nothing")
    func nothingOfferedGrantsNothing() async throws {
        let stub = StubSharing(participants: [
            ShareParticipantSummary(id: "_me", hasAccepted: true, permission: .readWrite, isOwner: true),
            ShareParticipantSummary(id: "_them", hasAccepted: true, permission: .readWrite, isOwner: false),
        ])

        #expect(try await stub.reconcileGrants(for: .coParent, kids: kids) == 0)
        #expect(stub.granted.isEmpty)
        #expect(stub.offered.isEmpty)
    }

    /// Inviting a co-parent must not make a child's zones look offered: the two
    /// roles have different anchors and are separate decisions a parent makes.
    @Test("An invitation for one role does not reconcile another")
    func rolesAreOfferedSeparately() async throws {
        let stub = StubSharing(participants: [
            ShareParticipantSummary(id: "_me", hasAccepted: true, permission: .readWrite, isOwner: true),
            ShareParticipantSummary(id: "_them", hasAccepted: true, permission: .readWrite, isOwner: false),
        ])

        _ = try await stub.invitation(for: .coParent, kids: kids)

        #expect(try await stub.reconcileGrants(for: .child(ada), kids: kids) == 0)
        #expect(try await stub.reconcileGrants(for: .coParent, kids: kids) > 0)
    }
}
