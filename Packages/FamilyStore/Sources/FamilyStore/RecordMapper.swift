import Foundation
import SwiftData

/// Encode only, deliberately — see ``RecordMapper`` for why inbound is separate.
public protocol SyncEncodable {
    /// `nil` when the key can't derive — never a fresh `UUID()`, which resent forever.
    var syncRecordName: String? { get }
    /// The type name, which is also what picks the merge rules.
    static var syncRecordType: String { get }
    /// Every field that travels.
    func syncFields() -> [String: SyncValue]
}

extension SyncEncodable {
    /// This row as a record, or `nil` when it cannot name itself.
    public func syncRecord() -> SyncedRecord? {
        guard let syncRecordName else { return nil }
        return SyncedRecord(
            name: syncRecordName, type: Self.syncRecordType, fields: syncFields())
    }
}

/// Outbound only — encoding is a total function of public getters, tested here.
/// Inbound isn't the mirror image: every property is `private(set)`, mutated
/// only through `modifiedAt`-stamping mutators, so unrestricted setters here
/// would break the invariant entry-level merge depends on.
/// Inbound is deferred, future work: a per-model `apply` through the mutators
/// that never drops a field it cannot map.
/// No cross-record references — every link is a plain identifier string, so
/// local and wire agree instead of drifting.
/// Every record name comes from ``NaturalKey``, never a fresh UUID, so two
/// devices producing the same logical row produce one record.
public enum RecordMapper {
    /// Checked against `SyncCoverage.syncedModels` — a mismatch fails the test.
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
    public var syncRecordName: String? { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        [Field.id: .uuid(id), Field.modifiedAt: .date(modifiedAt)]
    }
}

extension Kid: SyncEncodable {
    public static var syncRecordType: String { "Kid" }
    public var syncRecordName: String? { NaturalKey.identity(id) }

    public func syncFields() -> [String: SyncValue] {
        var fields: [String: SyncValue] = [
            Field.id: .uuid(id),
            Field.name: .string(name),
            Field.modifiedAt: .date(modifiedAt),
            // Cached columns travel too, for a device predating `SandboxSettingRecord`.
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
    public var syncRecordName: String? { NaturalKey.identity(id) }

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

    /// Keyed on content, not `id` — two offline denies merge to one row, not two.
    public var syncRecordName: String? {
        guard let kid else { return nil }
        return NaturalKey.policyEntry(
            kid: kid.id, kind: kind, itemKind: itemKind, catalogID: catalogID)
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
    public var syncRecordName: String? { NaturalKey.identity(id) }

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

    /// Keyed on `(kid, target)`; pre-`sourcePlaylistID` rows key the same as always.
    public var syncRecordName: String? {
        guard let kid else { return nil }
        let target = catalogID ?? (sourcePlaylistID ?? id).uuidString
        return NaturalKey.suggestion(kid: kid.id, target: target)
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

    public var syncRecordName: String? {
        guard let suggestion else { return nil }
        return NaturalKey.suggestionEntry(suggestion: suggestion.id, catalogID: catalogID)
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
        // Carried even though the parent implies it — zone placement needs it first.
        fields[Field.kidID] = suggestion?.kid.map { .uuid($0.id) }
        fields["artworkURL"] = artworkURL.map { .url($0) }
        return fields
    }
}

// MARK: - The kid's library

extension FavoriteRecord: SyncEncodable {
    public static var syncRecordType: String { "FavoriteRecord" }

    public var syncRecordName: String? {
        guard let kid else { return nil }
        return NaturalKey.favorite(kid: kid.id, itemKind: itemKind, catalogID: catalogID)
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
    public var syncRecordName: String? { NaturalKey.identity(id) }

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

    /// Not keyed on position — else a reorder looks like a bulk delete-and-insert.
    public var syncRecordName: String? {
        guard let playlist else { return nil }
        return NaturalKey.playlistEntry(playlist: playlist.id, catalogID: catalogID)
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
        // See ``SuggestionEntryRecord`` — the zone is chosen before relationships resolve.
        fields[Field.kidID] = playlist?.kid.map { .uuid($0.id) }
        fields["artworkURL"] = artworkURL.map { .url($0) }
        fields["origin"] = .string(origin)
        return fields
    }
}

// MARK: - Devices, gates, consent

extension DeviceRecord: SyncEncodable {
    public static var syncRecordType: String { "DeviceRecord" }
    public var syncRecordName: String? { NaturalKey.identity(id) }

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
    public var syncRecordName: String? { NaturalKey.identity(id) }

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
    public var syncRecordName: String? { NaturalKey.identity(id) }

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
    public var syncRecordName: String? { NaturalKey.identity(id) }

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

    /// Keyed by the writing device — two devices never write the same segment.
    public var syncRecordName: String? {
        guard let kidID, let deviceID else { return nil }
        return NaturalKey.activitySegment(
            kid: kidID,
            device: deviceID,
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

    public var syncRecordName: String? {
        guard let kid else { return nil }
        return NaturalKey.weeklySummary(kid: kid.id, weekStart: weekStart)
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
