import Foundation
import PolicyEngine

/// Where a play or block came from; a v1 event omitting it loses it forever.
public enum PlaybackOrigin: Hashable, Sendable {
    /// The home screen — the allow list in level 1, recents otherwise.
    case home

    /// A search, carrying the term the kid settled on.
    case search(term: String)

    /// Browsing a container: an artist's albums, or an album's tracks.
    case browse(CatalogID)

    /// A catalog playlist; unlike `browse`, a deny on it reaches its tracks.
    case playlist(CatalogID)

    /// Has no catalog ID — the one deliberate exception to that rule.
    case kidPlaylist(UUID)

    /// Distinct from `home` so "did they listen to what I picked?" stays answerable.
    case suggestion

    /// Same UUID exception as `kidPlaylist`, kept apart since child-made differs.
    case suggestedPlaylist(UUID)
}

// MARK: - Storage form

/// Beyond spec: two extra columns for `browse`, cheap now, unbackfillable later.
struct StoredOrigin: Codable {
    var name: String
    var term: String?
    var kind: String?
    var id: String?
}

extension PlaybackOrigin {
    /// Case names as stored. Frozen: changing one silently reinterprets history.
    enum Name {
        static let home = "home"
        static let search = "search"
        static let browse = "browse"
        static let playlist = "playlist"
        static let kidPlaylist = "kidPlaylist"
        static let suggestion = "suggestion"
        static let suggestedPlaylist = "suggestedPlaylist"
    }

    var stored: StoredOrigin {
        switch self {
        case .home:
            StoredOrigin(name: Name.home)
        case .search(let term):
            StoredOrigin(name: Name.search, term: term)
        case .browse(let id):
            StoredOrigin(name: Name.browse, kind: id.kind.rawValue, id: id.rawValue)
        case .playlist(let id):
            StoredOrigin(name: Name.playlist, kind: id.kind.rawValue, id: id.rawValue)
        case .kidPlaylist(let local):
            // No `kind`: this identifier is ours, not the catalog's — no `ItemKind` fits.
            StoredOrigin(name: Name.kidPlaylist, id: local.uuidString)
        case .suggestion:
            StoredOrigin(name: Name.suggestion)
        case .suggestedPlaylist(let local):
            // No `kind`, for the reason on `kidPlaylist`.
            StoredOrigin(name: Name.suggestedPlaylist, id: local.uuidString)
        }
    }

    /// `nil` on unreadable, never `.home` — a false origin beats admitting unknown.
    init?(stored: StoredOrigin) {
        switch stored.name {
        case Name.home:
            self = .home
        case Name.search:
            guard let term = stored.term else { return nil }
            self = .search(term: term)
        case Name.browse, Name.playlist:
            guard
                let rawKind = stored.kind,
                let kind = ItemKind(rawValue: rawKind),
                let raw = stored.id
            else { return nil }
            let id = CatalogID(kind, raw)
            self = stored.name == Name.browse ? .browse(id) : .playlist(id)
        case Name.kidPlaylist, Name.suggestedPlaylist:
            guard let raw = stored.id, let local = UUID(uuidString: raw) else { return nil }
            self = stored.name == Name.kidPlaylist ? .kidPlaylist(local) : .suggestedPlaylist(local)
        case Name.suggestion:
            self = .suggestion
        default:
            return nil
        }
    }
}

// MARK: - Coding

/// Routes through `StoredOrigin` so a case can't drift from the queue's encoding.
extension PlaybackOrigin: Codable {
    public func encode(to encoder: any Encoder) throws {
        try stored.encode(to: encoder)
    }

    public init(from decoder: any Decoder) throws {
        let stored = try StoredOrigin(from: decoder)
        guard let origin = PlaybackOrigin(stored: stored) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Not an origin: \(stored.name)"
                )
            )
        }
        self = origin
    }
}
