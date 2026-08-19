/// The kind of thing a catalog identifier points at.
///
/// These are the four types a parent can put on a list. MusicKit exposes more
/// (stations, curators, genres); the sandbox does not use them.
public enum ItemKind: String, Sendable, Codable, Hashable, CaseIterable {
    case artist
    case album
    case playlist
    case song
}

/// A reference to one item in the Apple Music catalog. The kind is part of the
/// identity: MusicKit identifiers are only unique within a type, so matching on
/// the raw string alone would let an album ID collide with a song ID and
/// quietly widen a parent's allow list.
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
