/// The four types a parent can list; MusicKit has more (stations, genres) unused.
public enum ItemKind: String, Sendable, Codable, Hashable, CaseIterable {
    case artist
    case album
    case playlist
    case song
}

/// Kind is part of identity — MusicKit ids are unique only within a type.
public struct CatalogID: Hashable, Sendable, Codable {
    public let kind: ItemKind
    public let rawValue: String

    public init(_ kind: ItemKind, _ rawValue: String) {
        self.kind = kind
        self.rawValue = rawValue
    }
}

extension CatalogID: CustomStringConvertible {
    public var description: String { "\(kind.rawValue):\(rawValue)" }
}
