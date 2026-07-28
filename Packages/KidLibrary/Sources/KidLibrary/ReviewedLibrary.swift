import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

/// The kid's shelf as the admin sees it: **never filtered, always annotated.**
///
/// The parallel of ``MergedLibrary/favorites()``, which filters. Both read the
/// same providers through the same seam, and only this one keeps the half the
/// kid cannot see — which is the half a parent opened the screen for. A denied
/// favorite is a row here and a missing tile there, and the two disagreeing is
/// the feature.
public struct ReviewedLibrary: Sendable {
    public let favorites: [Annotated<FavoriteRow>]
    public let playlists: [ReviewedPlaylist]

    /// One entry per provider this device has **configured**, live or not.
    ///
    /// A shelf that is short because a provider failed and a shelf that is short
    /// because the kid kept little look identical, and only one of them is about
    /// the child. Nothing here ever reaches a kid screen.
    ///
    /// Providers that do not exist yet are absent rather than reported as
    /// broken: the Apple Music provider is unbuilt, and listing it as failed
    /// would be describing our roadmap as a fault on this device.
    public let providers: [LibraryProviderID: ProviderHealth]

    /// Stored rows the catalog would not resolve on this read.
    ///
    /// **Not** the ISRC/UPC drop rate that open research question 2 asks about —
    /// that count belongs to the Apple provider's library-to-catalog pass, which
    /// does not exist yet. This is the narrower thing that is measurable today:
    /// rows we hold whose identifiers the catalog did not answer for, whether
    /// because the item was delisted or because the request failed.
    public let unresolved: Int

    /// False when the catalog did not answer at all, so every row was judged on
    /// its bare identifier. The screen says so once rather than per row.
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

    /// Favorites that arrived with the account rather than being chosen.
    ///
    /// A shelf that filled itself on the first read of an Apple Music library is
    /// visible as such rather than reading as a very busy week.
    public var adopted: [Annotated<FavoriteRow>] {
        favorites.filter { $0.fact.origin == .appleLibrary }
    }
}

public struct ReviewedPlaylist: Sendable, Identifiable {
    public let row: PlaylistRow
    public let entries: [Annotated<PlaylistEntryRow>]

    public var id: UUID { row.handle.local }

    /// The name is free text a child typed, and this screen is where a parent
    /// first reads it.
    public var name: String { row.name }

    /// True when our copy accepts edits that Apple's silently will not. A
    /// permanent divergence rather than a transient one, stated to the parent
    /// here and never to the kid.
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

    /// Deliberately not in use. **Not a fault** — an answer the parent gave, or
    /// a question nobody has put yet.
    case notConfigured(Reason)

    /// Threw on this read. Admin-facing; the kid's side swallows the same
    /// failure and says nothing, because one dead provider must not empty a
    /// shelf.
    case failed(String)

    public enum Reason: Sendable, Hashable {
        /// `isSharedDevice`: the library signed in here is a grown-up's.
        case sharedDevice

        /// Onboarding has not asked yet, so nothing may be read from the Apple
        /// Music library — the gate that stops an adult library landing on a
        /// child's shelf.
        case notYetAsked
    }
}
