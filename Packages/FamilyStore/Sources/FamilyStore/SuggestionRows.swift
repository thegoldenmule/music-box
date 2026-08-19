import Foundation
import PolicyEngine

/// What a suggestion points at — two kinds so the compiler enforces both.
public enum SuggestionTarget: Sendable, Hashable {
    /// The ordinary case: a catalog artist, album, song or playlist.
    case catalog(CatalogID)

    /// Unpublished, so no catalog id — a smuggled UUID would break artist-deny reach.
    case snapshotPlaylist(local: UUID)
}

/// A parent's shelf, never merged into the kid's library unless favorited.
public struct SuggestionRow: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let target: SuggestionTarget
    public let displayName: String
    public let subtitle: String?
    public let artworkURL: URL?

    /// Moves on a re-suggestion, unlike ``FavoriteRow/favoritedAt``.
    public let suggestedAt: Date

    /// Stored, not derived, so a future drag-to-reorder needs no schema change.
    public let position: Int

    /// A dismissed suggestion also stops granting reach; the row itself survives.
    public let dismissedAt: Date?

    /// A restore stamps this, not clearing `dismissedAt`, so merge can order both.
    public let restoredAt: Date?

    /// A parent's one line about why. Optional, and shown to the kid.
    public let note: String?

    /// A ``GrownUp/attribution``, not a name; what the home screen groups shelves on.
    public let addedBy: String?

    /// Their name as it read at write time — what the kid sees, e.g. "From Dad".
    public let addedByName: String?

    /// Resolved up front: `resolveAncestry` skips playlists, blocking tracks inside.
    public let entries: [PlaylistEntryRow]

    /// Must mirror ``SuggestionRecord/isDismissed`` — a bare `!= nil` once lied.
    public var isDismissed: Bool {
        guard let dismissedAt else { return false }
        guard let restoredAt else { return true }
        return dismissedAt > restoredAt
    }

    /// The catalog identifier, where there is one. `nil` for a snapshot.
    public var catalogID: CatalogID? {
        if case .catalog(let id) = target { return id }
        return nil
    }

    /// A snapshot is always a playlist.
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
        restoredAt: Date? = nil,
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
        self.restoredAt = restoredAt
        self.note = note
        self.addedBy = addedBy
        self.addedByName = addedByName
        self.entries = entries
    }
}

extension SuggestionRow {
    /// `nil` for a catalog target; never carries `appleLibraryID` — not ours to write.
    public var handle: PlaylistHandle? {
        guard case .snapshotPlaylist(let local) = target else { return nil }
        return PlaylistHandle(local: local)
    }
}
