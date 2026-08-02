import Foundation
import PolicyEngine
import SwiftData
import Testing

@testable import FamilyStore
@testable import FamilySync

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
private func newKid() throws -> (ModelContext, Family, Kid) {
    let context = ModelContext(try FamilyStore.inMemoryContainer())
    let family = Family(at: t0)
    let kid = Kid(name: "Ada", mode: .denyPlusAuto, unratedBehavior: .block, at: t0)
    context.insert(family)
    context.insert(kid)
    family.addKid(kid, at: t0)
    return (context, family, kid)
}

// MARK: -

@Suite("Every model that travels has a mapper")
struct MapperCoverage {
    /// Under a hand-rolled transport, *"this model does not sync"* and
    /// *"somebody forgot to write a mapper"* are the same observable state — a
    /// kind of row that simply never arrives on the other device, noticed months
    /// later. `SyncCoverage` declares the intent; this is what makes the
    /// omission a failure instead.
    @Test("The mapper list and the synced list agree exactly")
    func coverageMatches() {
        let declared = Set(SyncCoverage.syncedModels.map { String(describing: $0) })
        #expect(RecordMapper.encodableTypes == declared)
    }

    /// Nothing that stays on the device may have picked up a mapper by accident.
    @Test("Nothing local has a mapper")
    func localModelsHaveNoMapper() {
        let local = Set(SyncCoverage.neverSyncs.map { String(describing: $0) })
        #expect(RecordMapper.encodableTypes.intersection(local).isEmpty)
    }
}

// MARK: -

@Suite("What a record is called")
@MainActor
struct RecordNames {
    /// **The property content addressing exists for.** Two parents denying the
    /// same artist offline both mint a row with its own UUID; a name derived
    /// from the content makes them one record with a save conflict the merge
    /// settles, rather than two rows meaning one thing with nothing able to tell
    /// they are the same.
    @Test("Two devices adding the same deny produce one record name")
    func sameDenyOneName() throws {
        let (_, _, kidA) = try newKid()
        let (_, _, kidB) = try newKid()
        // Same child on two devices — the identity syncs, so the id matches.
        kidB.setSortIndex(0, at: t0)

        let onA = kidA.addEntry(kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: t0)
        let onB = Kid(id: kidA.id, name: "Ada", mode: .denyPlusAuto, at: t0)
        onB.family = kidA.family
        let second = onB.addEntry(
            kind: .deny, id: CatalogID(.artist, "artist-A"), displayName: "A", at: t0 + 60)

        #expect(onA.id != second.id)
        #expect(onA.syncRecordName == second.syncRecordName)
    }

    /// An allow and a deny on the same artist are two different statements.
    /// Folding them onto one record would let one parent's allow and another's
    /// deny overwrite each other silently, instead of both existing for the
    /// engine to resolve — where a deny already wins.
    @Test("An allow and a deny on one artist are two records")
    func allowAndDenyDiffer() throws {
        let (_, _, kid) = try newKid()
        let denied = kid.addEntry(kind: .deny, id: CatalogID(.artist, "x"), displayName: "X", at: t0)
        let allowed = kid.addEntry(kind: .allow, id: CatalogID(.album, "x"), displayName: "X", at: t0)

        #expect(denied.syncRecordName != allowed.syncRecordName)
    }

    /// MusicKit identifiers are only unique within a type, so the kind has to be
    /// part of the key or an album could collide with a song.
    @Test("The same identifier under two kinds is two records")
    func kindIsPartOfTheKey() throws {
        let (_, _, kid) = try newKid()
        let asAlbum = kid.addEntry(kind: .deny, id: CatalogID(.album, "x"), displayName: "X", at: t0)
        let asSong = kid.addEntry(kind: .deny, id: CatalogID(.song, "x"), displayName: "X", at: t0)

        #expect(asAlbum.syncRecordName != asSong.syncRecordName)
    }

    /// A record name is the record's identity on the server, so the derivation
    /// is as permanent as a column: changing it forks every existing record into
    /// a duplicate.
    @Test("A name is stable across encodes")
    func namesAreStable() throws {
        let (_, _, kid) = try newKid()
        let record = kid.addEntry(kind: .deny, id: CatalogID(.artist, "a"), displayName: "A", at: t0)

        #expect(record.syncRecordName == record.syncRecordName)
        #expect(record.syncRecord().name == record.syncRecordName)
    }

    /// The separator earns its keep: without it `("ab", "c")` and `("a", "bc")`
    /// hash to the same key.
    @Test("Key parts cannot run together")
    func partsAreSeparated() {
        #expect(NaturalKey.key("ab", "c") != NaturalKey.key("a", "bc"))
    }

    /// The name is a hash rather than a joined string partly for length and
    /// character-set reasons, and partly because a record *name* is metadata: a
    /// name in a child's zone should not spell out what the child listened to.
    @Test("A name does not leak what it was made from")
    func namesAreOpaque() throws {
        let (_, _, kid) = try newKid()
        let record = kid.addEntry(
            kind: .deny, id: CatalogID(.artist, "some-explicit-band"), displayName: "X", at: t0)

        #expect(record.syncRecordName.contains("some-explicit-band") == false)
        #expect(record.syncRecordName.count == 32)
    }

    /// The same song at a different position is the same song *moved*. Keying on
    /// position would make a reorder read as a bulk delete and re-insert.
    @Test("A playlist entry keeps its name across a reorder")
    func reorderKeepsNames() throws {
        let (_, _, kid) = try newKid()
        let playlist = kid.addPlaylist(named: "Car songs", at: t0)
        playlist.addSong(id: CatalogID(.song, "one"), displayName: "One", at: t0)
        playlist.addSong(id: CatalogID(.song, "two"), displayName: "Two", at: t0)

        let before = playlist.entries.map(\.syncRecordName).sorted()
        playlist.reorder(to: [CatalogID(.song, "two"), CatalogID(.song, "one")], at: t0)

        #expect(playlist.entries.map(\.syncRecordName).sorted() == before)
    }
}

// MARK: -

@Suite("What travels")
@MainActor
struct EncodedFields {
    /// **No references anywhere.** Every cross-record link is a plain identifier
    /// string, which is what lets a record in a kid's zone point at the
    /// household `Family` without a cross-zone reference — and what makes
    /// severing `Kid.family` unnecessary. The local relationship and the wire
    /// form agree instead of drifting.
    @Test("A relationship travels as an identifier")
    func relationshipsAreIdentifiers() throws {
        let (_, family, kid) = try newKid()

        #expect(kid.syncFields()[Field.familyID] == .uuid(family.id))

        let entry = kid.addEntry(kind: .deny, id: CatalogID(.artist, "a"), displayName: "A", at: t0)
        #expect(entry.syncFields()[Field.kidID] == .uuid(kid.id))
    }

    /// The whole retraction mechanism has to survive the trip, or the merge has
    /// nothing to compare.
    @Test("A retraction travels")
    func retractionTravels() throws {
        let (_, _, kid) = try newKid()
        let entry = kid.addEntry(kind: .deny, id: CatalogID(.artist, "a"), displayName: "A", at: t0)

        #expect(entry.syncFields()[Field.retractedAt] == nil)

        kid.removeEntry(entry, at: t0 + 600)
        #expect(entry.syncFields()[Field.retractedAt] == .date(t0 + 600))
    }

    /// The cached columns travel too. They are the answer for a household whose
    /// other device predates `SandboxSettingRecord`, and leaving them behind
    /// would hand that device a kid with no sandbox level at all.
    @Test("The cached sandbox columns travel alongside the decisions")
    func cachedColumnsTravel() throws {
        let (_, _, kid) = try newKid()
        kid.setMode(.allowOnly, at: t0 + 600)

        #expect(kid.syncFields()["mode"] == .string("allowOnly"))
        let decision = try #require(kid.sandboxSettings.first)
        #expect(decision.syncFields()["rawValue"] == .string("allowOnly"))
        #expect(decision.syncFields()[Field.kidID] == .uuid(kid.id))
    }

    /// A dismissal withdraws an allow, and a restore puts it back. Both have to
    /// be on the wire for the comparison to work — a restore that travelled as
    /// an *absence* would be undone by any device that had not seen it.
    @Test("Both halves of a dismissal travel")
    func dismissalTravels() throws {
        let (_, _, kid) = try newKid()
        let suggestion = kid.addSuggestion(
            target: .catalog(CatalogID(.album, "a")), displayName: "A", at: t0)

        suggestion.dismiss(at: t0 + 600)
        #expect(suggestion.syncFields()[Field.dismissedAt] == .date(t0 + 600))

        suggestion.restore(position: 1, at: t0 + 1200)
        #expect(suggestion.syncFields()[Field.dismissedAt] == .date(t0 + 600))
        #expect(suggestion.syncFields()[Field.restoredAt] == .date(t0 + 1200))
        #expect(suggestion.isDismissed == false)
    }

    @Test("A revocation travels as a tombstone")
    func revocationTravels() {
        let device = DeviceRecord(label: "Sam's iPad", role: .kidOnly, platform: .pad, at: t0)
        #expect(device.syncFields()[Field.revokedAt] == nil)

        device.revoke(at: t0 + 600)
        #expect(device.syncFields()[Field.revokedAt] == .date(t0 + 600))
    }

    /// Encoding then merging a record against itself must be a no-op — the
    /// simplest possible end-to-end check that the two halves agree about field
    /// names, which a typo in `Field` would otherwise break silently.
    @Test("A record merged with itself is unchanged")
    func selfMergeIsIdentity() throws {
        let (_, _, kid) = try newKid()
        let entry = kid.addEntry(kind: .deny, id: CatalogID(.artist, "a"), displayName: "A", at: t0)
        let encoded = entry.syncRecord()

        let outcome = Merge.resolve(
            local: encoded, remote: encoded, rules: Merge.rules(for: encoded.type))
        #expect(outcome.record.fields == encoded.fields)
        #expect(outcome.conflicts.isEmpty)
    }
}
