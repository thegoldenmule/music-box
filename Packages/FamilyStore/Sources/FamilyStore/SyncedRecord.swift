import Foundation

/// One field's worth of value on the wire.
///
/// A closed set, deliberately small, and it is what keeps CloudKit out of this
/// package. `CKRecord` accepts a wider range than this store needs; narrowing it
/// here means the adapter that eventually writes a `CKRecord` has a total
/// function to write rather than a set of guesses, and it means every merge rule
/// below can be exhaustive.
public enum SyncValue: Sendable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case date(Date)
    case data(Data)
    case uuid(UUID)
    case url(URL)
    case bool(Bool)
    case uuids([UUID])
}

/// A record as it travels: a name, a type, and flat fields.
///
/// **Nothing here is a CloudKit type**, and that is the point rather than a
/// convenience. This package holds the two decisions that are worth testing
/// exhaustively — what a record is *called* and how two versions of it are
/// reconciled — and both are pure functions of values. Keeping them clear of
/// `CKRecord` is the same seam `CatalogKit` puts around MusicKit, for the same
/// reason: the parts that decide something are testable with no network, no
/// entitlement and no device, and the part that cannot be tested here is a thin
/// mechanical adapter with no decisions in it.
public struct SyncedRecord: Sendable, Equatable {
    /// Derived from the natural key, never generated. See ``RecordName``.
    public let name: String

    /// The model's type name — `"PolicyEntryRecord"` and so on.
    public let type: String

    public var fields: [String: SyncValue]

    public init(name: String, type: String, fields: [String: SyncValue]) {
        self.name = name
        self.type = type
        self.fields = fields
    }

    public subscript(field: String) -> SyncValue? {
        get { fields[field] }
        set { fields[field] = newValue }
    }

    // MARK: - Typed reads
    //
    // `nil` rather than a default on a mismatch. A field that is the wrong shape
    // is a field written by a build that does not agree with this one, and
    // substituting a zero there is how a newer build's value becomes an older
    // build's default — the failure `SandboxSettingRecord` already guards
    // against one layer up.

    public func date(_ field: String) -> Date? {
        if case .date(let value) = fields[field] { return value }
        return nil
    }

    public func string(_ field: String) -> String? {
        if case .string(let value) = fields[field] { return value }
        return nil
    }

    public func int(_ field: String) -> Int? {
        if case .int(let value) = fields[field] { return value }
        return nil
    }

    public func uuid(_ field: String) -> UUID? {
        if case .uuid(let value) = fields[field] { return value }
        return nil
    }
}

/// Field names, in one place, because a typo in one of these is a field that
/// silently never merges.
public enum Field {
    public static let id = "id"
    public static let modifiedAt = "modifiedAt"
    public static let addedAt = "addedAt"
    public static let assertedAt = "assertedAt"
    public static let retractedAt = "retractedAt"
    public static let dismissedAt = "dismissedAt"
    public static let restoredAt = "restoredAt"
    public static let createdAt = "createdAt"
    public static let favoritedAt = "favoritedAt"
    public static let suggestedAt = "suggestedAt"
    public static let decidedAt = "decidedAt"
    public static let revokedAt = "revokedAt"
    public static let lastSeenAt = "lastSeenAt"
    public static let enrolledAt = "enrolledAt"
    public static let position = "position"
    public static let sortIndex = "sortIndex"
    public static let name = "name"
    public static let displayName = "displayName"
    public static let kidID = "kidID"
    public static let familyID = "familyID"
}
