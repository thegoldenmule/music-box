/// One entry on a kid's allow or deny list.
public struct PolicyEntry: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case allow
        case deny
    }

    public let kind: Kind
    public let id: CatalogID

    public init(kind: Kind, id: CatalogID) {
        self.kind = kind
        self.id = id
    }

    public static func allow(_ id: CatalogID) -> PolicyEntry {
        PolicyEntry(kind: .allow, id: id)
    }

    public static func deny(_ id: CatalogID) -> PolicyEntry {
        PolicyEntry(kind: .deny, id: id)
    }
}

/// Everything the engine needs to know about one kid's configuration.
///
/// Allow and deny are one list with a flag rather than two lists: they share a
/// shape and the engine reads both together, so splitting them would mean
/// writing every lookup twice.
public struct Policy: Hashable, Sendable, Codable {
    public let mode: SandboxMode
    public let entries: [PolicyEntry]
    public let unratedBehavior: UnratedBehavior

    public init(
        mode: SandboxMode,
        entries: [PolicyEntry] = [],
        unratedBehavior: UnratedBehavior = .block
    ) {
        self.mode = mode
        self.entries = entries
        self.unratedBehavior = unratedBehavior
    }
}
