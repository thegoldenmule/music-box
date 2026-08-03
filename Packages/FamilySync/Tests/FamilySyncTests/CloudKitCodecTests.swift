import CloudKit
import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import FamilyStore
@testable import FamilySync

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private let kidID = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!

@MainActor
private func seeded() throws -> (ModelContext, Family, Kid) {
    let context = ModelContext(try FamilyStore.inMemoryContainer())
    let family = Family(at: t0)
    let kid = Kid(id: kidID, name: "Ada", mode: .denyPlusAuto, unratedBehavior: .block, at: t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: t0)
    return (context, family, kid)
}

/// The tests are all owner-side, so they say so once here rather than at every
/// call. See ``HouseholdSide`` for why `ckRecord` will not assume it.
func ownedZoneID(_ zone: FamilyZone) -> CKRecordZone.ID {
    HouseholdSide.owner.zoneID(for: zone)
}

private func roundTrip(_ record: SyncedRecord, in zone: FamilyZone = .household) -> SyncedRecord {
    CloudKitCodec.syncedRecord(for: CloudKitCodec.ckRecord(for: record, in: ownedZoneID(zone)))
}

// MARK: -

@Suite("Every shape survives the trip")
struct ValueRoundTrip {
    /// `CKRecord` carries no Swift types — a `UUID` and a `String` both arrive as
    /// a string — so every shape has to be declared and read back deliberately.
    @Test("Each value kind comes back as itself")
    func allKindsRoundTrip() {
        let uuid = UUID()
        let original = SyncedRecord(
            name: "n", type: "PolicyEntryRecord",
            fields: [
                "id": .uuid(uuid),
                "catalogID": .string("artist-A"),
                "position": .int(1024),
                "modifiedAt": .date(t0),
                "payload": .data(Data([1, 2, 3])),
                "artworkURL": .url(URL(string: "https://example.invalid/a.jpg")!),
                "appleIsOurs": .bool(true),
                "kidIDs": .uuids([uuid]),
            ])

        #expect(roundTrip(original).fields == original.fields)
    }

    @Test("False survives, which an integer encoding makes easy to get wrong")
    func falseSurvives() {
        let original = SyncedRecord(
            name: "n", type: "PlaylistRecord", fields: ["appleIsOurs": .bool(false)])
        #expect(roundTrip(original).fields["appleIsOurs"] == .bool(false))
    }

    @Test("The name and type are the record's identity, not the payload's")
    func identitySurvives() {
        let original = SyncedRecord(name: "abc123", type: "FavoriteRecord", fields: [:])
        let ck = CloudKitCodec.ckRecord(for: original, in: ownedZoneID(.kidWork(kidID)))

        #expect(ck.recordID.recordName == "abc123")
        #expect(ck.recordType == "FavoriteRecord")
        #expect(ck.recordID.zoneID.zoneName == "kid-\(kidID.uuidString.lowercased())-work")
    }

    /// A field from a newer build has no declared shape. Reading it by runtime
    /// type carries it through this build rather than dropping it — the
    /// receiving side is what decides it cannot be placed, and it defers.
    @Test("An undeclared field is carried through, not dropped")
    func unknownFieldSurvives() {
        var original = SyncedRecord(name: "n", type: "Kid", fields: [:])
        original["somethingFromTheFuture"] = .string("hello")
        original["aNumberFromTheFuture"] = .int(7)

        let back = roundTrip(original)
        #expect(back.fields["somethingFromTheFuture"] == .string("hello"))
        #expect(back.fields["aNumberFromTheFuture"] == .int(7))
    }
}

// MARK: -

@Suite("What the wire must never contain")
@MainActor
struct WireRules {
    /// **No `CKRecord.Reference` anywhere.** A reference is scoped to one zone,
    /// and this design deliberately puts a kid's rows and the household they
    /// belong to in different zones — so a reference would either be illegal or
    /// would drag the graph into one zone and undo the topology.
    @Test("Cross-record links travel as identifiers, never references")
    func noReferences() throws {
        let (_, family, kid) = try seeded()
        let entry = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A Band", at: t0)

        for record in [family.syncRecord(), kid.syncRecord(), entry.syncRecord()] {
            let zone = try #require(FamilyZone.placing(record.type, kidID: kidID))
            let ck = CloudKitCodec.ckRecord(for: record, in: ownedZoneID(zone))
            for key in ck.allKeys() {
                #expect(ck[key] as? CKRecord.Reference == nil, "\(record.type).\(key)")
            }
        }

        // And the link is still there, as a string.
        #expect(kid.syncRecord().fields[Field.familyID] == .uuid(family.id))
    }

    /// Every field any encoder emits has a declared shape. Without this a new
    /// column travels as whatever the runtime type inspection guesses — a UUID
    /// as a string, say — and the receiving side defers on it forever with
    /// nothing saying why.
    @Test("Every field an encoder emits has a declared shape")
    func everyFieldHasAKind() throws {
        let (_, family, kid) = try seeded()
        kid.setMode(.allowOnly, at: t0)
        let entry = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "a"), displayName: "A", at: t0)
        let favorite = try #require(
            kid.addFavorite(id: CatalogID(.album, "b"), displayName: "B", at: t0))
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)
        let song = try #require(
            playlist.addSong(id: CatalogID(.song, "c"), displayName: "C", at: t0))
        let suggestion = kid.addSuggestion(
            target: .catalog(CatalogID(.album, "d")), displayName: "D", at: t0)
        let suggested = try #require(
            suggestion.addSong(id: CatalogID(.song, "e"), displayName: "E", at: t0))
        let grownUp = GrownUp(name: "Dad", at: t0)
        family.addGrownUp(grownUp, at: t0)
        let device = DeviceRecord(label: "Sam's iPad", role: .kidOnly, platform: .pad, at: t0)
        let epoch = PasscodeEpochRecord(epoch: 1, salt: Data([1]), verifier: Data([2]), at: t0)
        let clear = HistoryClearRecord(kidID: kid.id, clearedThrough: t0, at: t0)
        let consent = ConsentRecord(
            scope: .shareHousehold, kidIDs: [kid.id], appVersion: "1.0", at: t0)
        let segment = ActivitySegmentRecord(
            kidID: kid.id, deviceID: device.id, dayUTC: "2026-08-02", table: "plays", index: 0,
            payload: Data([3]), at: t0)
        let summary = WeeklySummaryRecord(weekStart: t0, payload: Data([4]), at: t0)

        let everything: [SyncedRecord] = [
            family.syncRecord(), kid.syncRecord(), grownUp.syncRecord(), entry.syncRecord(),
            try #require(kid.sandboxSettings.first).syncRecord(),
            suggestion.syncRecord(), suggested.syncRecord(), favorite.syncRecord(),
            playlist.syncRecord(), song.syncRecord(), device.syncRecord(), epoch.syncRecord(),
            clear.syncRecord(), consent.syncRecord(), segment.syncRecord(), summary.syncRecord(),
        ]

        var undeclared: Set<String> = []
        for record in everything {
            for field in record.fields.keys where FieldKind.table[field] == nil {
                undeclared.insert("\(record.type).\(field)")
            }
        }
        #expect(undeclared.isEmpty, "no declared shape for: \(undeclared.sorted())")
    }

    /// Encoding every record and reading it straight back must be the identity.
    /// The simplest end-to-end check that the two halves of this file agree.
    @Test("Every record type round-trips unchanged")
    func everyRecordRoundTrips() throws {
        let (_, family, kid) = try seeded()
        let entry = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "a"), displayName: "A Band", at: t0)
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)

        for record in [family.syncRecord(), kid.syncRecord(), entry.syncRecord(), playlist.syncRecord()] {
            let zone = try #require(FamilyZone.placing(record.type, kidID: kid.id))
            #expect(roundTrip(record, in: zone).fields == record.fields, "\(record.type)")
        }
    }
}

// MARK: -

@Suite("What Apple's servers cannot read")
@MainActor
struct EncryptionDisposition {
    /// **The most substantive thing available to the COPPA position**, and it
    /// exists only because we own the mapping: a child's playlist names and the
    /// notes an adult wrote about them are unreadable to the server rather than
    /// merely private by policy.
    @Test("Free text a person typed goes into the encrypted values")
    func freeTextIsEncrypted() throws {
        let (_, _, kid) = try seeded()
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)
        let ck = CloudKitCodec.ckRecord(for: playlist.syncRecord(), in: ownedZoneID(.kidWork(kid.id)))

        #expect(ck.encryptedValues["name"] as? String == "Car songs")
        // And not in the clear alongside it.
        #expect(ck["name"] == nil)
    }

    @Test("A child's name is encrypted, and their sandbox level is not")
    func namesEncryptedLevelsNot() throws {
        let (_, _, kid) = try seeded()
        let ck = CloudKitCodec.ckRecord(for: kid.syncRecord(), in: ownedZoneID(.kidPolicy(kid.id)))

        #expect(ck.encryptedValues["name"] as? String == "Ada")
        // The sandbox level is not a secret, and keeping it clear leaves it
        // usable in a server-side predicate if that is ever wanted.
        #expect(ck["mode"] as? String == "denyPlusAuto")
    }

    /// A verifier that can be read is a verifier that can be attacked offline.
    @Test("The passcode verifier and its salt are encrypted")
    func verifierIsEncrypted() {
        let epoch = PasscodeEpochRecord(epoch: 1, salt: Data([1]), verifier: Data([2]), at: t0)
        let ck = CloudKitCodec.ckRecord(for: epoch.syncRecord(), in: ownedZoneID(.household))

        #expect(ck["verifier"] == nil)
        #expect(ck["salt"] == nil)
        #expect(ck.encryptedValues["verifier"] as? Data == Data([2]))
    }

    /// An encrypted field still has to survive the trip, or the privacy is
    /// bought with data loss.
    @Test("Encrypted fields read back as themselves")
    func encryptedRoundTrips() throws {
        let (_, _, kid) = try seeded()
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)
        let record = playlist.syncRecord()

        #expect(roundTrip(record, in: .kidWork(kid.id)).fields == record.fields)
    }

    /// The activity payload is the child's listening in bulk. If
    /// `encryptedValues` turns out not to carry `Data` on a real container, this
    /// is the test that will say so — it passes locally and that is not the same
    /// thing as passing against CloudKit.
    @Test("The activity payload is encrypted and survives")
    func segmentPayloadIsEncrypted() {
        let segment = ActivitySegmentRecord(
            kidID: kidID, deviceID: UUID(), dayUTC: "2026-08-02", table: "plays", index: 0,
            payload: Data([1, 2, 3]), at: t0)
        let record = segment.syncRecord()
        let ck = CloudKitCodec.ckRecord(for: record, in: ownedZoneID(.kidWork(kidID)))

        #expect(ck["payload"] == nil)
        #expect(roundTrip(record, in: .kidWork(kidID)).fields["payload"] == .data(Data([1, 2, 3])))
    }
}

// MARK: -

@Suite("Where a record lives")
struct ZoneTopology {
    /// CloudKit has no per-record permissions inside a zone, so anything one
    /// person may read and another may not has to *be* a different zone.
    @Test("A child may write their own work and never their own policy")
    func policyIsReadOnlyToTheChild() {
        #expect(FamilyZone.kidPolicy(kidID).childMayWrite == false)
        #expect(FamilyZone.kidWork(kidID).childMayWrite)
        #expect(FamilyZone.household.childMayWrite == false)
    }

    @Test("What decides reach is in the policy zone")
    func policyZoneHoldsTheRules() {
        for type in ["Kid", "SandboxSettingRecord", "PolicyEntryRecord", "HistoryClearRecord"] {
            #expect(FamilyZone.placing(type, kidID: kidID) == .kidPolicy(kidID), "\(type)")
        }
    }

    /// **`SuggestionRecord` is in `work`, which is not where it first looks like
    /// it belongs.** A suggestion is a parent's and folds into the policy as an
    /// allow — but `dismiss()` is a kid-side write, and dismissal is what
    /// withdraws that allow. Read-only would mean the server rejecting a child
    /// tapping "no thanks" while the allow stayed live forever.
    @Test("A suggestion is writable by the child who may dismiss it")
    func suggestionsAreWritable() {
        #expect(FamilyZone.placing("SuggestionRecord", kidID: kidID) == .kidWork(kidID))
        #expect(FamilyZone.placing("SuggestionEntryRecord", kidID: kidID) == .kidWork(kidID))
    }

    @Test("The roster, the devices and the gate are the household's")
    func householdZone() {
        for type in ["Family", "GrownUp", "DeviceRecord", "PasscodeEpochRecord", "ConsentRecord"] {
            #expect(FamilyZone.placing(type, kidID: nil) == .household, "\(type)")
        }
    }

    /// Guessing here would put one child's data in another child's zone, so a
    /// kid-scoped record with no kid is refused rather than placed somewhere.
    @Test("A kid-scoped record with no kid cannot be placed")
    func unplaceableIsRefused() {
        #expect(FamilyZone.placing("PolicyEntryRecord", kidID: nil) == nil)
        #expect(FamilyZone.placing("FavoriteRecord", kidID: nil) == nil)
    }

    @Test("A zone name reads back as the zone it names")
    func zoneNamesRoundTrip() {
        for zone in [FamilyZone.household, .kidPolicy(kidID), .kidWork(kidID)] {
            #expect(FamilyZone(zoneName: zone.zoneName) == zone)
        }
        #expect(FamilyZone(zoneName: "something-else") == nil)
    }

    @Test("Every synced type has somewhere to live")
    func everySyncedTypeIsPlaced() {
        for type in RecordMapper.encodableTypes {
            #expect(FamilyZone.placing(type, kidID: kidID) != nil, "nowhere to put \(type)")
        }
    }
}
