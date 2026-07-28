import PolicyEngine

/// A rating as an event row keeps it.
///
/// `ContentRating?` is already a three-state problem — `.clean`, `.explicit`, or
/// no rating available — and writing one down turns it into a four-state one.
/// A column that is empty can mean the catalog had nothing to say, or that
/// whatever wrote the row had no rating to hand. Those are different facts and
/// only one of them is about the item.
///
/// Collapsing them would break the annotation the parent's report is built on:
/// under ``UnratedBehavior/block`` an item the catalog rated nothing is blocked
/// today and will be blocked tomorrow, which is worth telling a parent, while an
/// item nobody recorded a rating for is simply a row we cannot judge. Reporting
/// the second as the first would show a parent a wall of things their kid can
/// supposedly no longer play.
public enum StoredRating: Sendable, Hashable, Codable, CaseIterable {
    case clean
    case explicit

    /// The catalog answered and carried no rating. A recorded fact about the
    /// item; ``UnratedBehavior`` decides what to do with it.
    case unrated

    /// Nothing wrote a rating down. **Not** a fact about the item — the row was
    /// made somewhere that had no catalog item in hand, such as a block on a
    /// stored library row that never resolved.
    case unknown

    public init(_ rating: ContentRating?) {
        switch rating {
        case .clean: self = .clean
        case .explicit: self = .explicit
        case nil: self = .unrated
        }
    }

    /// What the engine should be told. `nil` for both empty cases — the engine
    /// has one way to say "no rating" and it is the right answer for each. The
    /// difference between them survives in ``isRecorded``, which is what decides
    /// whether the verdict is worth showing.
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
    /// As stored. Frozen: these are read back out of a parent's history months
    /// later, and a renamed case silently reinterprets it.
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

    /// Reads a rating back.
    ///
    /// An unreadable string becomes ``unknown`` rather than `nil`, which is the
    /// one place in this file that does not follow the codebase's usual
    /// "unreadable is `nil`" rule — and deliberately. `unknown` already *is* the
    /// "we do not know" case, so there is nothing a `nil` would add beyond
    /// discarding an otherwise perfectly readable row over a field that is
    /// advisory.
    init(stored: String) {
        switch stored {
        case Name.clean: self = .clean
        case Name.explicit: self = .explicit
        case Name.unrated: self = .unrated
        default: self = .unknown
        }
    }
}
