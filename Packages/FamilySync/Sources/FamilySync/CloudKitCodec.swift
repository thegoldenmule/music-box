import CloudKit
import FamilyStore
import Foundation

/// What shape a field is on the wire.
///
/// **A `CKRecord` does not carry Swift types.** A `UUID` and a `String` both
/// arrive as a string, and there is no asking the record which it meant. So the
/// shape has to be declared, and this is where — one table for the whole store,
/// because a field name means the same thing wherever it appears: `id` is always
/// a UUID, `position` always an integer, `payload` always data.
///
/// A field with no entry is not an error. It is a field from a **newer build**,
/// and it decodes by inspecting the value's runtime type instead — which
/// preserves it through this build rather than dropping it, at the cost of a
/// `UUID` from the future reading back as a string. The receiving side then
/// defers on it rather than acting on a guess. Losing it outright is the one
/// option not taken.
enum FieldKind: Sendable {
    case string, int, date, data, uuid, url, bool, uuids

    /// Every field any encoder emits. A test asserts that, so a new column
    /// without an entry here fails the build rather than silently travelling as
    /// the wrong shape.
    static let table: [String: FieldKind] = [
        // Identity and bookkeeping
        "id": .uuid, "modifiedAt": .date, "familyID": .uuid, "kidID": .uuid,
        "playlistID": .uuid, "suggestionID": .uuid, "sourcePlaylistID": .uuid,
        "originatingDeviceID": .uuid, "deviceID": .uuid,

        // Names and copied metadata
        "name": .string, "displayName": .string, "subtitle": .string, "note": .string,
        "label": .string, "appVersion": .string, "artworkURL": .url,

        // Catalog
        "catalogID": .string, "itemKind": .string, "kind": .string, "origin": .string,
        "albumID": .string, "albumName": .string, "artistID": .string, "artistName": .string,

        // Timestamps
        "addedAt": .date, "assertedAt": .date, "retractedAt": .date, "createdAt": .date,
        "favoritedAt": .date, "suggestedAt": .date, "dismissedAt": .date, "restoredAt": .date,
        "decidedAt": .date, "revokedAt": .date, "lastSeenAt": .date, "enrolledAt": .date,
        "setAt": .date, "clearedThrough": .date, "issuedAt": .date, "agreedAt": .date,
        "weekStart": .date,

        // Ordering
        "position": .int, "sortIndex": .int, "index": .int, "epoch": .int,

        // Sandbox and attribution
        "mode": .string, "unratedBehavior": .string, "keyRaw": .string, "rawValue": .string,
        "addedBy": .string, "addedByName": .string,
        "decidedByAccountRecordName": .string, "decidedByGrownUpID": .uuid,
        "accountRecordName": .string, "boundAccountRecordName": .string,

        // Devices, gates, consent
        "roleRaw": .string, "platformRaw": .string, "boundKidID": .uuid,
        "enrolledAccountRecordName": .string, "enrolledByGrownUpID": .uuid,
        "setByGrownUpID": .uuid, "issuedByGrownUpID": .uuid,
        "salt": .data, "verifier": .data,
        "scopeRaw": .string, "kidIDs": .uuids,

        // Library
        "appleLibraryID": .string, "appleIsOurs": .bool,

        // Activity
        "dayUTC": .string, "table": .string, "payload": .data,
    ]
}

/// Which fields never leave this device in the clear.
///
/// **The single most substantive thing available to the COPPA position, and it
/// exists only because we own the mapping.** A mirroring layer decides this for
/// you; hand-rolling it means a child's search terms, the playlist names they
/// typed and the notes a parent wrote about them are unreadable to Apple's
/// servers rather than merely private by policy.
///
/// A set of field *names* rather than a per-type table, deliberately. It errs
/// toward encrypting: a new column called `displayName` on some future record is
/// covered without anyone remembering, and the cost of encrypting something that
/// did not need it is that it cannot be used in a server-side predicate — which
/// nothing here does.
///
/// **This disposition is the hardest one-way door in the design.** A promoted
/// CloudKit schema is additive-only, and moving a field between clear and
/// encrypted after the fact is understood to require a new field under a new
/// name — which is to say the old values stay where they are, forever. That
/// specific corollary is a strong reading of the additive-only rule rather than
/// something found documented, and it is worth confirming before promotion.
enum Encrypted {
    static let fields: Set<String> = [
        "name",  // a child's name, and a playlist name a child typed
        "displayName",  // what they were looking at
        "subtitle",
        "note",  // free text an adult wrote about a child
        "label",  // "Sam's iPad"
        "addedByName",
        "payload",  // rolled-up activity, and weekly summaries
        "artworkURL",  // the URL names the album
        "albumName",
        "artistName",
        "verifier",  // a passcode verifier has no business being readable
        "salt",
    ]

    static func covers(_ field: String) -> Bool { fields.contains(field) }
}

/// Turns a ``SyncedRecord`` into a `CKRecord` and back.
///
/// **The only file in the project that imports CloudKit, and it contains no
/// decisions.** Everything that decides something — what a record is called, how
/// two copies reconcile, which zone a record belongs in, which child a device
/// opens — is a pure value type tested with `swift test`. What is left here is a
/// mapping, and it is deliberately dull.
///
/// Two rules it holds to, both tested:
///
/// - **No `CKRecord.Reference` anywhere.** Every cross-record link travels as a
///   plain identifier string. A reference is scoped to one zone, and this design
///   puts a kid's rows and the household they belong to in *different* zones —
///   so a reference would either be illegal or would drag the graph into one
///   zone and undo the topology. It is also what lets the local SwiftData
///   relationship and the wire form stay in agreement instead of drifting.
/// - **Record names come from ``NaturalKey``**, never from `CKRecord`'s default
///   UUID. Two devices producing one logical row produce one record.
public enum CloudKitCodec {
    /// The `CKRecord` for a record, placed in a zone.
    ///
    /// Takes the zone's `ID` rather than a ``FamilyZone`` because the zone alone
    /// does not say whose it is — see ``HouseholdSide``. The caller has already
    /// had to decide, so it passes the decision in rather than letting this
    /// re-derive it as "mine".
    public static func ckRecord(for record: SyncedRecord, in zoneID: CKRecordZone.ID) -> CKRecord {
        let id = CKRecord.ID(recordName: record.name, zoneID: zoneID)
        let ck = CKRecord(recordType: record.type, recordID: id)
        for (field, value) in record.fields {
            write(value, to: ck, as: field)
        }
        return ck
    }

    /// The record a `CKRecord` describes.
    ///
    /// Never `nil`: a record whose fields this build does not recognise still
    /// round-trips, because the receiving side is what decides whether it can be
    /// placed — and it defers rather than dropping. Refusing here would throw
    /// away a row on the way past.
    public static func syncedRecord(for ck: CKRecord) -> SyncedRecord {
        var fields: [String: SyncValue] = [:]
        for field in ck.allKeys() {
            if let value = read(field, from: ck) { fields[field] = value }
        }
        for field in Encrypted.fields where fields[field] == nil {
            if let value = read(field, from: ck) { fields[field] = value }
        }
        return SyncedRecord(name: ck.recordID.recordName, type: ck.recordType, fields: fields)
    }

    // MARK: -

    private static func write(_ value: SyncValue, to ck: CKRecord, as field: String) {
        let stored: any CKRecordValueProtocol =
            switch value {
            case .string(let v): v
            case .int(let v): v
            case .date(let v): v
            case .data(let v): v
            case .uuid(let v): v.uuidString
            case .url(let v): v.absoluteString
            // CKRecord has no boolean. An integer rather than a string so a
            // future server-side predicate could still compare it.
            case .bool(let v): v ? 1 : 0
            case .uuids(let v): v.map(\.uuidString)
            }

        if Encrypted.covers(field) {
            ck.encryptedValues[field] = stored
        } else {
            ck[field] = stored
        }
    }

    private static func read(_ field: String, from ck: CKRecord) -> SyncValue? {
        let raw: Any? = Encrypted.covers(field) ? ck.encryptedValues[field] : ck[field]
        guard let raw else { return nil }

        // The declared shape first. Falling back to the runtime type is what
        // carries a field from a newer build through this one intact.
        switch FieldKind.table[field] {
        case .uuid: return (raw as? String).flatMap(UUID.init(uuidString:)).map(SyncValue.uuid)
        case .url: return (raw as? String).flatMap(URL.init(string:)).map(SyncValue.url)
        case .bool: return (raw as? Int).map { SyncValue.bool($0 != 0) }
        case .uuids:
            guard let strings = raw as? [String] else { return nil }
            return .uuids(strings.compactMap(UUID.init(uuidString:)))
        case .string: return (raw as? String).map(SyncValue.string)
        case .int: return (raw as? Int).map(SyncValue.int)
        case .date: return (raw as? Date).map(SyncValue.date)
        case .data: return (raw as? Data).map(SyncValue.data)
        case nil:
            switch raw {
            case let v as Date: return .date(v)
            case let v as Data: return .data(v)
            case let v as Int: return .int(v)
            case let v as String: return .string(v)
            case let v as [String]: return .uuids(v.compactMap(UUID.init(uuidString:)))
            default: return nil
            }
        }
    }
}
