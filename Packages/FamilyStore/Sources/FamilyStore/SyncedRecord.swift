import Foundation

/// Closed and small — the adapter to `CKRecord` gets a total function to write.
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

/// No CloudKit type here — naming and merging stay pure and testable.
public struct SyncedRecord: Sendable, Equatable {
    /// Derived from the natural key, never generated.
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

    // `nil` on mismatch, never a default — a newer value must not become a zero.

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

/// One place, because a typo here is a field that silently never merges.
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
