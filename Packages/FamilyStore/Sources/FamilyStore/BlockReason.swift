import PolicyEngine

/// Engine ``Reason`` plus outside refusals, kept apart from a parent's rule.
public enum BlockReason: Hashable, Sendable {
    /// Level 1: the parent never added this, or anything containing it.
    case notOnAllowList

    /// The item or a container was denied; carries which entry matched.
    case deniedByParent(CatalogID)

    /// Level 2: the catalog marks this explicit.
    case explicitContent

    /// Level 2: no rating available, and `UnratedBehavior` said to block.
    case unrated

    /// Screen Time or Apple Music parental controls, not a parent's rule.
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
    /// Frozen — read back out of a parent's history months later.
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

    /// `nil` on unreadable columns — never degrades to a bare "denied".
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

/// Routes through `StoredReason` so block columns and a segment can't drift.
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
