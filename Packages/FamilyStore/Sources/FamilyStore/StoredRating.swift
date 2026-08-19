import PolicyEngine

/// Distinguishes the catalog saying "no rating" from nobody ever recording one.
public enum StoredRating: Sendable, Hashable, Codable, CaseIterable {
    case clean
    case explicit

    /// The catalog answered with no rating — a fact; ``UnratedBehavior`` decides.
    case unrated

    /// No rating was ever recorded — not a fact about the item itself.
    case unknown

    public init(_ rating: ContentRating?) {
        switch rating {
        case .clean: self = .clean
        case .explicit: self = .explicit
        case nil: self = .unrated
        }
    }

    /// `nil` for both empty cases; ``isRecorded`` keeps them distinguishable.
    public var rating: ContentRating? {
        switch self {
        case .clean: .clean
        case .explicit: .explicit
        case .unrated, .unknown: nil
        }
    }

    /// Whether this says anything about the item at all.
    public var isRecorded: Bool { self != .unknown }
}

// MARK: - Storage form

extension StoredRating {
    /// Stored names are frozen — renaming a case would reinterpret old rows.
    enum Name {
        static let clean = "clean"
        static let explicit = "explicit"
        static let unrated = "unrated"
        static let unknown = "unknown"
    }

    var stored: String {
        switch self {
        case .clean: Name.clean
        case .explicit: Name.explicit
        case .unrated: Name.unrated
        case .unknown: Name.unknown
        }
    }

    /// An unreadable row becomes ``unknown``, not `nil`, which already means unsure.
    init(stored: String) {
        switch stored {
        case Name.clean: self = .clean
        case Name.explicit: self = .explicit
        case Name.unrated: self = .unrated
        default: self = .unknown
        }
    }
}
