import PolicyEngine

/// Why a block was logged.
///
/// A superset of the engine's ``Reason``: everything the policy engine can
/// decide, plus the one cause that comes from outside our process.
///
/// The distinction is the point. Screen Time's music restriction and Apple
/// Music's own parental controls can refuse playback for reasons that have
/// nothing to do with a parent's list. Folding those into
/// ``deniedByParent(_:)`` would show a parent their own rule blocking something
/// they never denied.
public enum BlockReason: Hashable, Sendable {
    /// Level 1: the parent never added this, or anything containing it.
    case notOnAllowList

    /// The parent denied this item or one of its containers, and which entry
    /// matched — so the report can say *which* deny did it.
    case deniedByParent(CatalogID)

    /// Level 2: the catalog marks this explicit.
    case explicitContent

    /// Level 2: no rating available, and `UnratedBehavior` said to block.
    case unrated

    /// Refused outside our process — Screen Time, or Apple Music's parental
    /// controls. Never attributed to a parent's own rule.
    case restrictedOutsideApp

    public init(_ reason: Reason) {
        switch reason {
        case .notOnAllowList: self = .notOnAllowList
        case .deniedByParent(let id): self = .deniedByParent(id)
        case .explicitContent: self = .explicitContent
        case .unrated: self = .unrated
        }
    }
}

// MARK: - Storage form

struct StoredReason: Codable {
    var name: String
    var deniedByKind: String?
    var deniedByID: String?
}

extension BlockReason {
    /// Reason names as stored. Frozen: these are read back out of a parent's
    /// history months later.
    enum Name {
        static let notOnAllowList = "notOnAllowList"
        static let deniedByParent = "deniedByParent"
        static let explicitContent = "explicitContent"
        static let unrated = "unrated"
        static let restrictedOutsideApp = "restrictedOutsideApp"
    }

    var stored: StoredReason {
        switch self {
        case .notOnAllowList:
            StoredReason(name: Name.notOnAllowList)
        case .deniedByParent(let id):
            StoredReason(
                name: Name.deniedByParent,
                deniedByKind: id.kind.rawValue,
                deniedByID: id.rawValue
            )
        case .explicitContent:
            StoredReason(name: Name.explicitContent)
        case .unrated:
            StoredReason(name: Name.unrated)
        case .restrictedOutsideApp:
            StoredReason(name: Name.restrictedOutsideApp)
        }
    }

    /// Reads a reason back, or `nil` when the columns do not make one.
    ///
    /// A `deniedByParent` row whose identifier is unreadable comes back `nil`
    /// rather than degrading to a bare "denied": the entry it names is what
    /// makes that row actionable, and a reason that cannot say which rule fired
    /// is not the same reason.
    init?(stored: StoredReason) {
        switch stored.name {
        case Name.notOnAllowList:
            self = .notOnAllowList
        case Name.deniedByParent:
            guard
                let rawKind = stored.deniedByKind,
                let kind = ItemKind(rawValue: rawKind),
                let raw = stored.deniedByID
            else { return nil }
            self = .deniedByParent(CatalogID(kind, raw))
        case Name.explicitContent:
            self = .explicitContent
        case Name.unrated:
            self = .unrated
        case Name.restrictedOutsideApp:
            self = .restrictedOutsideApp
        default:
            return nil
        }
    }
}

// MARK: - Coding

/// **One wire format, and it is the one the columns already use** — the same
/// argument ``PlaybackOrigin``'s conformance makes, for the same reason. A reason
/// is now written in two places, the block columns and an activity segment, and
/// synthesising `Codable` for an enum with associated values would give the second
/// its own shape. Then a case added here needs remembering twice and the two drift
/// apart silently. Routing through ``StoredReason`` means the frozen names in
/// ``BlockReason/Name`` govern both.
///
/// Decoding something that does not make a reason **throws** rather than degrading
/// to a bare "denied", which is the call ``init(stored:)`` already makes: a
/// `deniedByParent` whose identifier is unreadable cannot say which rule fired, and
/// that is not the same reason.
extension BlockReason: Codable {
    public func encode(to encoder: any Encoder) throws {
        try stored.encode(to: encoder)
    }

    public init(from decoder: any Decoder) throws {
        let stored = try StoredReason(from: decoder)
        guard let reason = BlockReason(stored: stored) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Not a reason: \(stored.name)"
                )
            )
        }
        self = reason
    }
}
