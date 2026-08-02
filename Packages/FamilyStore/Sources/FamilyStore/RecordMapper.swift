import Foundation
import SwiftData

/// A model that can be put on the wire.
///
/// Encode only, deliberately — see ``RecordMapper`` for why the inbound half is
/// a separate decision rather than an omission.
public protocol SyncEncodable {
    /// The record's identity on the server, derived from its natural key.
    var syncRecordName: String { get }
    /// The type name, which is also what picks the merge rules.
    static var syncRecordType: String { get }
    /// Every field that travels.
    func syncFields() -> [String: SyncValue]
}

extension SyncEncodable {
    public func syncRecord() -> SyncedRecord {
        SyncedRecord(name: syncRecordName, type: Self.syncRecordType, fields: syncFields())
    }
}

/// Turns the store's models into records.
///
/// **Outbound only, and that is a scoped decision.** Encoding is a total
/// function of public getters, so it is written and tested here. Applying a
/// remote record is not the mirror image of it: every stored property in
/// `FamilyStore` is `private(set)` and changes only through mutators that stamp
/// `modifiedAt`, which is the invariant entry-level merge depends on and is
/// enforced structurally rather than by discipline. Handing this package
/// unrestricted setters to write through would dismantle that on the way past.
///
/// So the inbound half is its own design — a per-model `apply` that goes through
/// the mutators, with a stated answer for a field it cannot map (**never drop
/// it**, for the reason a migration may never drop a row). It is the next piece
/// of work and it is deliberately not improvised here.
///
/// Two rules the encoders hold to, both testable:
///
/// - **No references anywhere.** Every cross-record link is a plain identifier
///   string. A record in a kid's zone can then point at the household `Family`
///   without a cross-zone reference — which is what makes severing `Kid.family`
///   unnecessary, and it means the local relationship and the wire form agree
///   instead of drifting.
/// - **Every record name comes from ``NaturalKey``**, never from a fresh UUID.
///   Two devices producing the same logical row produce one record.
public enum RecordMapper {
    /// Every model `SyncCoverage` says travels, by type name.
    ///
    /// Compared against `SyncCoverage.syncedModels` by a test, so a model added
    /// to one and not the other fails rather than quietly never syncing.
    public static let encodableTypes: Set<String> = [
        "Family",
        "Kid",
        "GrownUp",
        "PolicyEntryRecord",
        "SandboxSettingRecord",
        "SuggestionRecord",
        "SuggestionEntryRecord",
        "FavoriteRecord",
        "PlaylistRecord",
        "PlaylistEntryRecord",
        "DeviceRecord",
        "PasscodeEpochRecord",
        "HistoryClearRecord",
        "ConsentRecord",
        "ActivitySegmentRecord",
        "WeeklySummaryRecord",
    ]
}

// MARK: - Household

extension Family: SyncEncodable {
    public static var syncRecordType: String { "Family" }
    public var syncRecordName: String { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        [Field.id: .uuid(id), Field.modifiedAt: .date(modifiedAt)]
    }
}

extension Kid: SyncEncodable {
    public static var syncRecordType: String { "Kid" }
    public var syncRecordName: String { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            Field.name: .string(name),
            Field.modifiedAt: .date(modifiedAt),
            // The cached columns travel too. They are the answer for a household
            // whose other device predates `SandboxSettingRecord`, and leaving
            // them behind would hand that device a kid with no sandbox level.
            "mode": .string(mode.rawValue),
            "unratedBehavior": .string(unratedBehavior.rawValue),
        ]
        fields[Field.familyID] = family.map { .uuid($0.id) }
        fields["boundAccountRecordName"] = boundAccountRecordName.map { .string($0) }
        fields[Field.sortIndex] = sortIndex.map { .int($0) }
        return fields
    }
}

extension GrownUp: SyncEncodable {
    public static var syncRecordType: String { "GrownUp" }
    public var syncRecordName: String { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            Field.name: .string(name),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.familyID] = family.map { .uuid($0.id) }
        fields["accountRecordName"] = accountRecordName.map { .string($0) }
        fields[Field.sortIndex] = sortIndex.map { .int($0) }
        return fields
    }
}

// MARK: - Policy

extension PolicyEntryRecord: SyncEncodable {
    public static var syncRecordType: String { "PolicyEntryRecord" }

    /// Keyed on `(kid, kind, itemKind, catalogID)` and **not** on `id`. Two
    /// parents denying the same artist offline both mint a row; content
    /// addressing makes them one record with a save conflict the merge settles,
    /// rather than two rows meaning one thing.
    public var syncRecordName: String {
        NaturalKey.policyEntry(
            kid: kid?.id ?? UUID(), kind: kind, itemKind: itemKind, catalogID: catalogID)
    }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "kind": .string(kind),
            "itemKind": .string(itemKind),
            "catalogID": .string(catalogID),
            Field.displayName: .string(displayName),
            Field.addedAt: .date(addedAt),
            Field.assertedAt: .date(assertedAt),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.kidID] = kid.map { .uuid($0.id) }
        fields[Field.retractedAt] = retractedAt.map { .date($0) }
        fields["artworkURL"] = artworkURL.map { .url($0) }
        fields["addedBy"] = addedBy.map { .string($0) }
        fields["addedByName"] = addedByName.map { .string($0) }
        fields["originatingDeviceID"] = originatingDeviceID.map { .uuid($0) }
        return fields
    }
}

extension SandboxSettingRecord: SyncEncodable {
    public static var syncRecordType: String { "SandboxSettingRecord" }
    public var syncRecordName: String { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "keyRaw": .string(keyRaw),
            "rawValue": .string(rawValue),
            Field.decidedAt: .date(decidedAt),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.kidID] = kid.map { .uuid($0.id) }
        fields["decidedByAccountRecordName"] = decidedByAccountRecordName.map { .string($0) }
        fields["decidedByGrownUpID"] = decidedByGrownUpID.map { .uuid($0) }
        fields["originatingDeviceID"] = originatingDeviceID.map { .uuid($0) }
        return fields
    }
}

// MARK: - Suggestions

extension SuggestionRecord: SyncEncodable {
    public static var syncRecordType: String { "SuggestionRecord" }

    /// Keyed on `(kid, target)`. The target string is the catalog identifier, or
    /// the local playlist UUID for a snapshot — read through `sourcePlaylistID`
    /// so a row written before that column keys the same way it always did.
    public var syncRecordName: String {
        let target = catalogID ?? (sourcePlaylistID ?? id).uuidString
        return NaturalKey.suggestion(kid: kid?.id ?? UUID(), target: target)
    }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "itemKind": .string(itemKind),
            Field.displayName: .string(displayName),
            Field.position: .int(position),
            Field.suggestedAt: .date(suggestedAt),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.kidID] = kid.map { .uuid($0.id) }
        fields["catalogID"] = catalogID.map { .string($0) }
        fields["sourcePlaylistID"] = sourcePlaylistID.map { .uuid($0) }
        fields[Field.dismissedAt] = dismissedAt.map { .date($0) }
        fields[Field.restoredAt] = restoredAt.map { .date($0) }
        fields["subtitle"] = subtitle.map { .string($0) }
        fields["artworkURL"] = artworkURL.map { .url($0) }
        fields["note"] = note.map { .string($0) }
        fields["addedBy"] = addedBy.map { .string($0) }
        fields["addedByName"] = addedByName.map { .string($0) }
        return fields
    }
}

extension SuggestionEntryRecord: SyncEncodable {
    public static var syncRecordType: String { "SuggestionEntryRecord" }

    public var syncRecordName: String {
        NaturalKey.suggestionEntry(suggestion: suggestion?.id ?? UUID(), catalogID: catalogID)
    }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "catalogID": .string(catalogID),
            Field.displayName: .string(displayName),
            Field.position: .int(position),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields["suggestionID"] = suggestion.map { .uuid($0.id) }
        fields["artworkURL"] = artworkURL.map { .url($0) }
        return fields
    }
}

// MARK: - The kid's library

extension FavoriteRecord: SyncEncodable {
    public static var syncRecordType: String { "FavoriteRecord" }

    public var syncRecordName: String {
        NaturalKey.favorite(kid: kid?.id ?? UUID(), itemKind: itemKind, catalogID: catalogID)
    }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "catalogID": .string(catalogID),
            "itemKind": .string(itemKind),
            Field.displayName: .string(displayName),
            "origin": .string(origin),
            Field.favoritedAt: .date(favoritedAt),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.kidID] = kid.map { .uuid($0.id) }
        fields["artworkURL"] = artworkURL.map { .url($0) }
        fields["albumID"] = albumID.map { .string($0) }
        fields["albumName"] = albumName.map { .string($0) }
        fields["artistID"] = artistID.map { .string($0) }
        fields["artistName"] = artistName.map { .string($0) }
        return fields
    }
}

extension PlaylistRecord: SyncEncodable {
    public static var syncRecordType: String { "PlaylistRecord" }
    public var syncRecordName: String { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            Field.name: .string(name),
            "origin": .string(origin),
            Field.createdAt: .date(createdAt),
            Field.modifiedAt: .date(modifiedAt),
            "appleIsOurs": .bool(appleIsOurs),
        ]
        fields[Field.kidID] = kid.map { .uuid($0.id) }
        fields["appleLibraryID"] = appleLibraryID.map { .string($0) }
        return fields
    }
}

extension PlaylistEntryRecord: SyncEncodable {
    public static var syncRecordType: String { "PlaylistEntryRecord" }

    /// Keyed on `(playlist, catalogID)` and **not on position** — the same song
    /// at a different position is the same song moved, and keying on position
    /// would make a reorder look like a bulk delete and re-insert.
    public var syncRecordName: String {
        NaturalKey.playlistEntry(playlist: playlist?.id ?? UUID(), catalogID: catalogID)
    }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "catalogID": .string(catalogID),
            Field.displayName: .string(displayName),
            Field.position: .int(position),
            Field.addedAt: .date(addedAt),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields["playlistID"] = playlist.map { .uuid($0.id) }
        fields["artworkURL"] = artworkURL.map { .url($0) }
        fields["origin"] = .string(origin)
        return fields
    }
}

// MARK: - Devices, gates, consent

extension DeviceRecord: SyncEncodable {
    public static var syncRecordType: String { "DeviceRecord" }
    public var syncRecordName: String { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "label": .string(label),
            "roleRaw": .string(roleRaw),
            "platformRaw": .string(platformRaw),
            Field.enrolledAt: .date(enrolledAt),
            Field.lastSeenAt: .date(lastSeenAt),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.familyID] = familyID.map { .uuid($0) }
        fields["boundKidID"] = boundKidID.map { .uuid($0) }
        fields["enrolledAccountRecordName"] = enrolledAccountRecordName.map { .string($0) }
        fields["enrolledByGrownUpID"] = enrolledByGrownUpID.map { .uuid($0) }
        fields[Field.revokedAt] = revokedAt.map { .date($0) }
        return fields
    }
}

extension PasscodeEpochRecord: SyncEncodable {
    public static var syncRecordType: String { "PasscodeEpochRecord" }
    public var syncRecordName: String { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "epoch": .int(epoch),
            "salt": .data(salt),
            "verifier": .data(verifier),
            "setAt": .date(setAt),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.familyID] = familyID.map { .uuid($0) }
        fields["setByGrownUpID"] = setByGrownUpID.map { .uuid($0) }
        return fields
    }
}

extension HistoryClearRecord: SyncEncodable {
    public static var syncRecordType: String { "HistoryClearRecord" }
    public var syncRecordName: String { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "clearedThrough": .date(clearedThrough),
            "issuedAt": .date(issuedAt),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.kidID] = kidID.map { .uuid($0) }
        fields["issuedByGrownUpID"] = issuedByGrownUpID.map { .uuid($0) }
        return fields
    }
}

extension ConsentRecord: SyncEncodable {
    public static var syncRecordType: String { "ConsentRecord" }
    public var syncRecordName: String { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "scopeRaw": .string(scopeRaw),
            "kidIDs": .uuids(kidIDs),
            "agreedAt": .date(agreedAt),
            "appVersion": .string(appVersion),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.familyID] = familyID.map { .uuid($0) }
        fields["grownUpID"] = grownUpID.map { .uuid($0) }
        fields["accountRecordName"] = accountRecordName.map { .string($0) }
        return fields
    }
}

// MARK: - Activity

extension ActivitySegmentRecord: SyncEncodable {
    public static var syncRecordType: String { "ActivitySegmentRecord" }

    /// Keyed by the **writing device**, which is what gives the volume leader in
    /// this store no conflict surface at all — two devices never write the same
    /// segment. See ``NaturalKey/activitySegment(kid:device:dayUTC:table:index:)``
    /// for the limit of that claim.
    public var syncRecordName: String {
        NaturalKey.activitySegment(
            kid: kidID ?? UUID(),
            device: deviceID ?? UUID(),
            dayUTC: dayUTC,
            table: table,
            index: index
        )
    }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "dayUTC": .string(dayUTC),
            "table": .string(table),
            "index": .int(index),
            "payload": .data(payload),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.kidID] = kidID.map { .uuid($0) }
        fields["deviceID"] = deviceID.map { .uuid($0) }
        return fields
    }
}

extension WeeklySummaryRecord: SyncEncodable {
    public static var syncRecordType: String { "WeeklySummaryRecord" }

    public var syncRecordName: String {
        NaturalKey.weeklySummary(kid: kid?.id ?? UUID(), weekStart: weekStart)
    }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            "weekStart": .date(weekStart),
            "payload": .data(payload),
            Field.modifiedAt: .date(modifiedAt),
        ]
        fields[Field.kidID] = kid.map { .uuid($0.id) }
        return fields
    }
}
