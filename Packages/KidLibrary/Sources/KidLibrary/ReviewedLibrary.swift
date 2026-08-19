import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

/// The admin's unfiltered shelf — a denied favorite is a row here, no tile there.
public struct ReviewedLibrary: Sendable {
    public let favorites: [Annotated<FavoriteRow>]
    public let playlists: [ReviewedPlaylist]

    /// One entry per configured provider; failed and sparse look identical here.
    public let providers: [LibraryProviderID: ProviderHealth]

    /// Stored rows the catalog wouldn't resolve — delisted, or the request failed.
    public let unresolved: Int

    /// False when the catalog didn't answer; the screen says so once, not per row.
    public let isResolved: Bool

    public init(
        favorites: [Annotated<FavoriteRow>],
        playlists: [ReviewedPlaylist],
        providers: [LibraryProviderID: ProviderHealth],
        unresolved: Int,
        isResolved: Bool
    ) {
        self.favorites = favorites
        self.playlists = playlists
        self.providers = providers
        self.unresolved = unresolved
        self.isResolved = isResolved
    }

    /// Favorites the kid could not play today. What a parent came to see.
    public var blockedFavorites: [Annotated<FavoriteRow>] {
        favorites.filter { $0.isAllowedNow == false }
    }

    /// Favorites that arrived with the account, not chosen by the kid.
    public var adopted: [Annotated<FavoriteRow>] {
        favorites.filter { $0.fact.origin == .appleLibrary }
    }
}

public struct ReviewedPlaylist: Sendable, Identifiable {
    public let row: PlaylistRow
    public let entries: [Annotated<PlaylistEntryRow>]

    public var id: UUID { row.handle.local }

    /// Free text a child typed; a parent first reads it here.
    public var name: String { row.name }

    /// True when our copy takes an edit Apple's silently won't — a permanent gap.
    public var divergesFromApple: Bool {
        row.handle.appleLibraryID != nil && !row.appleIsOurs
    }

    public var blockedCount: Int { entries.filter { $0.isAllowedNow == false }.count }

    public init(row: PlaylistRow, entries: [Annotated<PlaylistEntryRow>]) {
        self.row = row
        self.entries = entries
    }
}

/// What one provider contributed to a read.
public enum ProviderHealth: Sendable, Hashable {
    case live

    /// Deliberately unused — not a fault, an answer given, or unasked.
    case notConfigured(Reason)

    /// Threw here; the kid's side swallows it, so one dead provider stays hidden.
    case failed(String)

    public enum Reason: Sendable, Hashable {
        /// `isSharedDevice`: the library signed in here is a grown-up's.
        case sharedDevice

        /// Onboarding hasn't asked, so nothing reads from an adult's library.
        case notYetAsked
    }
}
