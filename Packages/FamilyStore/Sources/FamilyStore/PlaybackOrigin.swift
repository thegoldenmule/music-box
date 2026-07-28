import Foundation
import PolicyEngine

/// Where a play or a block came from.
///
/// Mirrors the player's `Origin`. It is here rather than in the player because
/// it is a stored column: what a v1 event does not record about its own origin
/// is absent from that period forever.
public enum PlaybackOrigin: Hashable, Sendable {
    /// The home screen — the allow list in level 1, recents otherwise.
    case home

    /// A search, carrying the term the kid settled on.
    case search(term: String)

    /// Browsing a container: an artist's albums, or an album's tracks.
    case browse(CatalogID)

    /// A catalog playlist. Kept distinct from ``browse(_:)`` because a playlist
    /// is part of a track's lineage when the track is played from it, and a deny
    /// on the playlist has to reach it.
    case playlist(CatalogID)

    /// One of the kid's own playlists, by its local identifier.
    ///
    /// A separate case rather than a ``playlist(_:)`` with a made-up identifier
    /// inside it, because a kid's playlist has no catalog identifier — it did
    /// not exist until they made it — and every other identifier this store
    /// keeps is an Apple Music one. Folding a UUID into that namespace would
    /// break the rule that makes a deny on an artist reach their tracks.
    ///
    /// It is also not lineage. A parent cannot deny their kid's own playlist;
    /// they deny what is in it. So this origin says where a play came from and
    /// nothing more, which is exactly what the report wants of it.
    case kidPlaylist(UUID)
}

// MARK: - Storage form

/// The four columns an origin costs.
///
/// The spec's schema named two of them — `origin` and `originTerm` — which
/// covers ``PlaybackOrigin/home`` and ``PlaybackOrigin/search(term:)`` and
/// loses the identifier on the other two. `browse` can be an artist *or* an
/// album, so the kind cannot be inferred from the discriminator either. Both
/// extra columns are cheap now and impossible to backfill later, so they are
/// here from v1 even though nothing reads them yet.
struct StoredOrigin {
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
            // No `kind`: the identifier is ours, not the catalog's, and there is
            // no `ItemKind` that honestly describes it.
            StoredOrigin(name: Name.kidPlaylist, id: local.uuidString)
        }
    }

    /// Reads an origin back, or `nil` if the columns do not make one.
    ///
    /// Unreadable is `nil` rather than a fallback to `.home`: a report that
    /// silently claims every orphaned row came from the home screen is worse
    /// than one that admits it does not know.
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
        case Name.kidPlaylist:
            guard let raw = stored.id, let local = UUID(uuidString: raw) else { return nil }
            self = .kidPlaylist(local)
        default:
            return nil
        }
    }
}
