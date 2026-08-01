import Foundation
import PolicyEngine

/// What a suggestion points at.
///
/// Two shapes rather than an optional identifier, because the difference is not
/// "some rows are missing a field" — it is two kinds of thing that behave
/// differently everywhere they are handled, and a total enum makes the compiler
/// say so at each site.
public enum SuggestionTarget: Sendable, Hashable {
    /// An artist, album, song or playlist that exists in the Apple Music
    /// catalog. The ordinary case.
    case catalog(CatalogID)

    /// A playlist that exists only here, carrying the local identifier that
    /// names it.
    ///
    /// **The second deliberate exception to the one-namespace rule**, after
    /// ``PlaybackOrigin/kidPlaylist(_:)`` — and a separate case for the same
    /// reason that one is: a UUID smuggled into ``CatalogID`` would break the
    /// rule that makes a deny on an artist reach their tracks.
    ///
    /// A parent's own Apple Music playlist has no catalog identifier — nobody
    /// published it — so suggesting one snapshots its tracks by ISRC instead.
    /// What the kid opens is a list of catalog songs under a name their parent
    /// chose.
    case snapshotPlaylist(local: UUID)
}

/// One thing a parent put in front of their kid.
///
/// **Not the kid's library, and never merged into it.** A suggestion is the
/// parent's shelf. It becomes the kid's only if the kid favorites what is on it,
/// which writes an ordinary ``FavoriteRow`` and leaves this row alone.
///
/// `displayName`, `subtitle` and `artworkURL` are copied at write time and never
/// refreshed, the same trade every other row in this store makes: the shelf
/// renders offline, and a delisted item still reads as a name.
public struct SuggestionRow: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let target: SuggestionTarget
    public let displayName: String
    public let subtitle: String?
    public let artworkURL: URL?

    /// When the parent last suggested it. Moves on a re-suggestion, unlike
    /// ``FavoriteRow/favoritedAt`` — see ``Kid/addSuggestion(target:displayName:subtitle:artworkURL:note:addedBy:at:)``.
    public let suggestedAt: Date

    /// Monotonic within a kid, ascending. The shelf sorts on it **descending**,
    /// so newest is first.
    ///
    /// Stored rather than derived from ``suggestedAt`` so that a future
    /// drag-to-reorder has somewhere to write without a schema change, and
    /// assigned as one-past-the-highest so that inserting never rewrites the
    /// rows around it — fifty touched `modifiedAt` stamps per suggestion is
    /// exactly the sync churn this store is built to avoid.
    public let position: Int

    /// When the kid passed on it, or `nil` while it is live.
    ///
    /// **A dismissed suggestion also stops granting reach** — see
    /// ``Kid/buildPolicy()``. The row survives so the parent can see it was
    /// passed on and offer it again; what does not survive is the allow.
    public let dismissedAt: Date?

    /// A parent's one line about why. Optional, and shown to the kid.
    public let note: String?

    /// Which grown-up picked it — a ``GrownUp/attribution``, not a name. `nil`
    /// when the roster is empty. What the home screen groups shelves on.
    public let addedBy: String?

    /// Their name as it read at write time. What the kid actually sees — "From
    /// Dad" — and `nil` falls back to the wording that names nobody.
    public let addedByName: String?

    /// The songs this suggestion resolves to, in order. Empty for everything
    /// that is not a playlist.
    ///
    /// **Every playlist suggestion carries these, catalog ones included.** It
    /// would be tempting to fetch a catalog playlist's tracks on demand and keep
    /// only its identifier, but nothing in this app puts a playlist into a
    /// track's lineage: `resolveAncestry` skips playlists deliberately, and no
    /// caller synthesises the ancestor. So an allow on a playlist identifier
    /// reaches the playlist and none of its contents, and a kid at level 1 would
    /// open a suggested playlist onto forty blocked rows. Resolving the tracks
    /// up front is what makes the tile mean what it looks like.
    public let entries: [PlaylistEntryRow]

    public var isDismissed: Bool { dismissedAt != nil }

    /// The catalog identifier, where there is one. `nil` for a snapshot.
    public var catalogID: CatalogID? {
        if case .catalog(let id) = target { return id }
        return nil
    }

    /// What kind of thing this is, including for a snapshot — which is always a
    /// playlist.
    public var itemKind: ItemKind {
        switch target {
        case .catalog(let id): id.kind
        case .snapshotPlaylist: .playlist
        }
    }

    public init(
        id: UUID,
        target: SuggestionTarget,
        displayName: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        suggestedAt: Date,
        position: Int,
        dismissedAt: Date? = nil,
        note: String? = nil,
        addedBy: String? = nil,
        addedByName: String? = nil,
        entries: [PlaylistEntryRow] = []
    ) {
        self.id = id
        self.target = target
        self.displayName = displayName
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.suggestedAt = suggestedAt
        self.position = position
        self.dismissedAt = dismissedAt
        self.note = note
        self.addedBy = addedBy
        self.addedByName = addedByName
        self.entries = entries
    }
}

extension SuggestionRow {
    /// A snapshot playlist's handle, so it can be opened by the same route a
    /// kid's own playlist is.
    ///
    /// `nil` for everything else: an album has no handle, it has an identifier.
    /// There is never an `appleLibraryID` here — the parent's playlist is theirs,
    /// and this app has no business writing to it.
    public var handle: PlaylistHandle? {
        guard case .snapshotPlaylist(let local) = target else { return nil }
        return PlaylistHandle(local: local)
    }
}
