import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

/// What a shelf actually draws, after the engine has had its say.
///
/// Blocked items are **kept, never dropped**: a parent may have denied something
/// their kid favorited last week, and that is a line in the report rather than a
/// silent disappearance.
public struct LibraryResults: Sendable, Hashable {
    /// What the kid may see, in the order the shelf wants them.
    public let items: [CatalogItem]

    /// What the engine turned down, with its reason.
    public let blocked: [BlockedItem]

    /// Whether the catalog answered at all.
    ///
    /// False means the rows were drawn from the copies stored at write time and
    /// judged on bare identifiers with no rating and no lineage — a provisional
    /// verdict, in the sense the whole codebase uses the word. Not shown to a
    /// kid; the player's re-check is what makes it safe.
    public let isResolved: Bool

    public init(items: [CatalogItem], blocked: [BlockedItem], isResolved: Bool) {
        self.items = items
        self.blocked = blocked
        self.isResolved = isResolved
    }

    public static let empty = LibraryResults(items: [], blocked: [], isResolved: true)
}

/// The write the policy engine refused.
///
/// A kid may only favorite, or add to a playlist, what they may currently play.
/// This is what that refusal looks like to a caller — which is expected to log
/// the block and say nothing to the kid, because the item was never on their
/// screen in the first place.
public struct LibraryRefused: Error, Hashable, Sendable {
    public let item: CatalogItem
    public let reason: Reason

    public init(item: CatalogItem, reason: Reason) {
        self.item = item
        self.reason = reason
    }
}

/// No provider was there to do the work.
///
/// Only reachable by breaking the invariant that our own store is always live —
/// which is what makes every other failure in this file survivable. Kept as a
/// real error rather than a crash because a store that will not open is a device
/// problem, not a programming one.
public struct LibraryUnavailable: Error, Hashable, Sendable {
    public init() {}
}

/// The kid's library, across every provider holding part of it.
///
/// **This is the only thing callers talk to.** No surface names a provider, asks
/// which one something lives in, or learns that one of them failed. What a
/// provider cannot do, another carries; what a provider does not have, another
/// supplies; and if every provider but ours is gone, the shelf is still right,
/// because ours is always live.
///
/// Rebuilt when the kid or their policy changes, the way `FilteredCatalog` is:
/// the engine indexes a kid's lists once, and holding it here keeps every read
/// on this screen judged by the same policy.
@MainActor
public final class MergedLibrary {
    private let providers: [any LibraryProvider]
    private let catalog: any CatalogSource
    private let engine: PolicyEngine
    private let device: any DeviceLibraryStateStore

    public init(
        providers: [any LibraryProvider],
        catalog: any CatalogSource,
        engine: PolicyEngine,
        device: any DeviceLibraryStateStore
    ) {
        self.providers = providers
        self.catalog = catalog
        self.engine = engine
        self.device = device
    }

    // MARK: - Which providers are live

    /// `isSharedDevice` is the **only** input. False, the default: both. True:
    /// CloudKit alone. There is no other gate and no derived trust state.
    private var liveProviders: [any LibraryProvider] {
        let isShared = device.state.isSharedDevice
        return providers.filter { $0.id == .cloudKit || !isShared }
    }

    /// The live providers that may be **read from** on this pass.
    ///
    /// A second, narrower list rather than a condition folded into liveness,
    /// because the two rules are about different moments. Liveness is
    /// `isSharedDevice` and nothing else. This is the separate invariant that
    /// the Apple provider's first read waits for onboarding to put the question
    /// — a read is what adopts an unvetted library onto a child's shelf, and a
    /// write is not.
    private var readableProviders: [any LibraryProvider] {
        let hasBeenAsked = device.state.hasBeenAsked
        return liveProviders.filter { $0.id == .cloudKit || hasBeenAsked }
    }

    /// Providers that will be written to for this kind of favorite.
    ///
    /// A provider without the capability is skipped, not failed. An artist
    /// favorite that Apple Music has no primitive for is still a favorite in our
    /// records, and the kid sees no difference.
    private func writers(favoriting kind: ItemKind) -> [any LibraryProvider] {
        liveProviders.filter { $0.canFavorite(kind) }
    }

    // MARK: - Reading

    /// Every favorite this kid may still see, most recent first.
    ///
    /// The shelf is built the way Recent is: resolved from stored identifiers in
    /// one batched request and **filtered at render time**, never stored
    /// pre-filtered. A parent may deny tomorrow what the kid favorited today —
    /// the row survives, the tile does not.
    public func favorites() async throws -> LibraryResults {
        let rows = await mergedFavoriteRows()
        return await judge(
            rows.map { Stored(id: $0.catalogID, name: $0.displayName, artworkURL: $0.artworkURL) }
        )
    }

    /// Identifiers of everything favorited, unfiltered and unresolved.
    ///
    /// What the heart reads: a local set lookup against rows already in memory,
    /// costing nothing and needing no request. Deliberately **not** policy
    /// filtered — this answers "is this favorited", and a blocked item never
    /// reaches a screen that could ask.
    public func favoriteIDs() async -> Set<CatalogID> {
        Set(await mergedFavoriteRows().map(\.catalogID))
    }

    /// Every playlist, most recently touched first.
    ///
    /// Not filtered: a playlist is not a catalog item and the engine has no
    /// opinion on one. Its *songs* are judged, when they are asked for.
    public func playlists() async -> [PlaylistRow] {
        var merged: [UUID: PlaylistRow] = [:]
        for provider in readableProviders {
            // A provider that throws contributes nothing to this pass and is not
            // an error. There is nothing to tell a kid and nothing to retry.
            guard let rows = try? await provider.playlists() else { continue }
            for row in rows where merged[row.handle.local] == nil {
                merged[row.handle.local] = row
            }
        }
        return merged.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func playlist(_ handle: PlaylistHandle) async -> PlaylistRow? {
        await playlists().first { $0.handle.local == handle.local }
    }

    /// The songs in one playlist, in order, filtered.
    ///
    /// Order is the content, so this preserves it rather than sorting by
    /// anything of its own. A blocked track is absent from `items` and present in
    /// `blocked` — which is what the player skips over rather than stopping on.
    public func songs(in handle: PlaylistHandle) async throws -> LibraryResults {
        guard let row = await playlist(handle) else { return .empty }
        return await judge(
            row.entries.map {
                Stored(id: $0.catalogID, name: $0.displayName, artworkURL: $0.artworkURL)
            }
        )
    }

    /// Search the kid's own library.
    ///
    /// A local predicate over rows already in hand — favorites plus every
    /// playlist entry, deduplicated. `MusicLibrarySearchRequest` is deliberately
    /// **not** used: it searches the whole signed-in library rather than the
    /// kid's own records, which is the door this feature is careful not to open.
    ///
    /// Reached from the shelf rather than from the main search field. A kid with
    /// forty favorites does not need it; a kid with four hundred does, and that
    /// kid exists a year in.
    public func searchLibrary(_ term: String) async throws -> LibraryResults {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        var stored: [Stored] = []
        var seen: Set<CatalogID> = []
        for row in await mergedFavoriteRows() where seen.insert(row.catalogID).inserted {
            stored.append(
                Stored(id: row.catalogID, name: row.displayName, artworkURL: row.artworkURL)
            )
        }
        for playlist in await playlists() {
            for entry in playlist.entries where seen.insert(entry.catalogID).inserted {
                stored.append(
                    Stored(
                        id: entry.catalogID,
                        name: entry.displayName,
                        artworkURL: entry.artworkURL
                    )
                )
            }
        }

        // Filter first, match second. Matching on the resolved item means the
        // subtitle — the artist name — is searchable, which is most of what a kid
        // types, and the copied `displayName` is only ever the title.
        let judged = await judge(stored)
        return LibraryResults(
            items: judged.items.filter { $0.matches(trimmed) },
            blocked: judged.blocked,
            isResolved: judged.isResolved
        )
    }

    // MARK: - Writing

    /// Marks one item, in every live provider that has a primitive for its kind.
    ///
    /// **Asks the engine first and refuses a blocked item.** A favorite is not a
    /// permission and never becomes one; what a kid may keep is a subset of what
    /// they may play, decided by the same authority.
    ///
    /// Our own store is awaited and its failure is surfaced. Every other provider
    /// is fire-and-forget and its failure is dropped: the item lives in CloudKit,
    /// the union puts it on the shelf anyway, and the only cost is that it is not
    /// in the kid's Apple Music library.
    public func addFavorite(_ item: CatalogItem, origin: LibraryOrigin = .kid) async throws {
        let resolved = try await withAncestry(item)
        if case .blocked(let reason) = engine.evaluate(resolved.policyItem) {
            throw LibraryRefused(item: resolved, reason: reason)
        }

        for provider in writers(favoriting: item.id.kind) {
            try await write(to: provider) {
                try await $0.addFavorite(
                    item.id,
                    displayName: item.title,
                    artworkURL: item.artworkURL,
                    origin: origin
                )
            }
        }
    }

    /// Unmarking is never refused.
    ///
    /// The engine is not asked, and deliberately: a kid taking something off
    /// their own shelf is not reaching for anything, and refusing it would strand
    /// a favorite the parent has since denied on a screen where it cannot be
    /// removed.
    public func removeFavorite(_ id: CatalogID) async throws {
        for provider in liveProviders where provider.canFavorite(id.kind) {
            try await write(to: provider) { try await $0.removeFavorite(id) }
        }
    }

    /// Makes a playlist out of whatever survives the engine.
    ///
    /// Blocked songs are dropped rather than refused — a kid selecting six songs
    /// where one has been denied since should get a playlist of five, not an
    /// error. If **nothing** survives there is no playlist to make, and that is
    /// the one refusal.
    @discardableResult
    public func createPlaylist(named name: String, songs: [CatalogItem] = []) async throws
        -> PlaylistRow
    {
        let allowed = try await allowedSongs(songs)
        if !songs.isEmpty, allowed.isEmpty {
            throw LibraryRefused(item: songs[0], reason: .notOnAllowList)
        }

        var created: PlaylistRow?
        for provider in liveProviders where provider.capabilities.contains(.createPlaylists) {
            try await write(to: provider) {
                let row = try await $0.createPlaylist(named: name, songs: allowed)
                // Ours is the one whose handle callers keep: `local` is stable and
                // survives everything, and a provider that failed has no handle
                // to offer.
                if $0.id == .cloudKit { created = row }
            }
        }

        guard let created else { throw LibraryUnavailable() }
        return created
    }

    /// **Playlist entries are always songs.** An album or an artist is silently
    /// not added rather than refused: what would play is ambiguous, the player
    /// queues songs, and no screen offers the gesture in the first place.
    public func addToPlaylist(_ handle: PlaylistHandle, song: CatalogItem) async throws {
        guard song.id.kind == .song else { return }

        let resolved = try await withAncestry(song)
        if case .blocked(let reason) = engine.evaluate(resolved.policyItem) {
            throw LibraryRefused(item: resolved, reason: reason)
        }

        try await edit(handle) { try await $0.addToPlaylist(handle, song: song) }
    }

    public func removeFromPlaylist(_ handle: PlaylistHandle, song: CatalogID) async throws {
        try await edit(handle) { try await $0.removeFromPlaylist(handle, song: song) }
    }

    public func reorderPlaylist(_ handle: PlaylistHandle, to order: [CatalogID]) async throws {
        try await edit(handle) { try await $0.reorderPlaylist(handle, to: order) }
    }

    public func renamePlaylist(_ handle: PlaylistHandle, to name: String) async throws {
        try await edit(handle) { try await $0.renamePlaylist(handle, to: name) }
    }

    public func deletePlaylist(_ handle: PlaylistHandle) async throws {
        try await edit(handle) { try await $0.deletePlaylist(handle) }
    }

    // MARK: - Applying a write

    /// Runs one edit on every provider entitled to make it.
    ///
    /// **An edit is never attempted on a playlist we did not create.** MusicKit
    /// refuses one and exposes no way to ask which those are, so `appleIsOurs` —
    /// written at creation, never inferred — is what decides.
    ///
    /// Expressed through ``LibraryCapabilities/editForeignPlaylists`` rather
    /// than by naming MusicKit here. The rule belongs to that provider, and the
    /// provider declares it; a store that hard-coded it would make the flag dead
    /// and would cripple any future provider that genuinely can edit anything.
    ///
    /// A playlist that fails this test still shows and still plays; our copy is
    /// edited and Apple's is not, which is stated to the parent in the admin and
    /// never to the kid.
    private func edit(
        _ handle: PlaylistHandle,
        _ body: (any LibraryProvider) async throws -> Void
    ) async throws {
        let row = await playlist(handle)
        for provider in liveProviders {
            guard mayEdit(row, with: provider) else { continue }
            try await write(to: provider) { try await body($0) }
        }
    }

    private func mayEdit(_ row: PlaylistRow?, with provider: any LibraryProvider) -> Bool {
        guard provider.id != .cloudKit else { return true }
        guard let row, row.handle.appleLibraryID != nil else { return false }
        if row.appleIsOurs {
            return provider.capabilities.contains(.editOwnPlaylists)
        }
        return provider.capabilities.contains(.editForeignPlaylists)
    }

    /// **Our store is awaited and surfaced; every other provider is dropped.**
    ///
    /// A heart must not fill on a write that did not land, and a copy that did
    /// not reach Apple must never block the kid. There is no retry and no queue:
    /// the divergence that leaves is real, known, and made invisible where it
    /// matters by the read being a union.
    private func write(
        to provider: any LibraryProvider,
        _ body: (any LibraryProvider) async throws -> Void
    ) async throws {
        if provider.id == .cloudKit {
            try await body(provider)
        } else {
            try? await body(provider)
        }
    }

    // MARK: - Merging and judging

    /// Every provider's favorites, unioned by identifier, most recent first.
    ///
    /// A union, and **CloudKit only ever expands it**: nothing here prunes what
    /// another provider returned, contradicts it, or writes back into it. An item
    /// in our store and absent from Apple Music simply appears — which is why a
    /// failed Apple write costs the kid nothing visible.
    ///
    /// What Stage 3 adds here, and deliberately not yet: resolving Apple rows
    /// from library identifiers to catalog ones by ISRC and UPC, dropping
    /// whatever will not resolve, and adopting anything absent from our store as
    /// an `appleLibrary` row so it survives the provider going away.
    private func mergedFavoriteRows() async -> [FavoriteRow] {
        var merged: [CatalogID: FavoriteRow] = [:]
        for provider in readableProviders {
            guard let rows = try? await provider.favorites() else { continue }
            for row in rows where merged[row.catalogID] == nil {
                merged[row.catalogID] = row
            }
        }
        return merged.values.sorted { $0.favoritedAt > $1.favoritedAt }
    }

    /// What a row knows about itself without the catalog's help.
    private struct Stored {
        let id: CatalogID
        let name: String
        let artworkURL: URL?

        /// The copy made at write time. What a shelf draws when the catalog is
        /// not reachable — `displayName` and `artworkURL` are copied for exactly
        /// this, so a list renders offline.
        var fallback: CatalogItem {
            CatalogItem(id: id, title: name, artworkURL: artworkURL)
        }
    }

    /// Resolves stored rows against the catalog and applies the kid's policy.
    ///
    /// Order is the caller's throughout — a shelf is most-recent-first and a
    /// playlist is in the order the kid put it in, and neither survives being
    /// reshuffled by whatever came back from a batch request.
    ///
    /// **A catalog that will not answer does not empty the shelf.** The rows are
    /// judged on their bare identifiers instead, which is the same provisional
    /// verdict the rest of the app computes on unresolved ancestry: a deny still
    /// bites, `allowOnly` still fails closed, and only the rating check — the one
    /// thing that genuinely needs the catalog — cannot run. The player asks again
    /// immediately before playback, which is what makes that safe rather than
    /// merely convenient.
    private func judge(_ stored: [Stored]) async -> LibraryResults {
        guard !stored.isEmpty else { return .empty }

        var resolved: [CatalogID: CatalogItem] = [:]
        var isResolved = true
        do {
            let items = try await catalog.items(for: stored.map(\.id))
            // Lineage before judgement, in one batch, as everywhere else: a song
            // cannot be judged against a denied artist without knowing who its
            // artist is.
            for item in try await catalog.resolveAncestry(for: items) {
                resolved[item.id] = item
            }
        } catch {
            isResolved = false
        }

        var allowed: [CatalogItem] = []
        var blocked: [BlockedItem] = []
        for row in stored {
            // A resolved item that came back is judged on everything it knows.
            // One that did not — delisted, or the whole request failed — is
            // judged on its identifier alone.
            let item = resolved[row.id] ?? row.fallback
            switch engine.evaluate(item.policyItem) {
            case .allowed:
                allowed.append(item)
            case .blocked(let reason):
                blocked.append(BlockedItem(item: item, reason: reason))
            }
        }

        return LibraryResults(items: allowed, blocked: blocked, isResolved: isResolved)
    }

    /// Everything in this batch the kid may currently play.
    private func allowedSongs(_ songs: [CatalogItem]) async throws -> [CatalogItem] {
        guard !songs.isEmpty else { return [] }
        let resolved = try await catalog.resolveAncestry(for: songs)
        return resolved.filter { $0.id.kind == .song && engine.evaluate($0.policyItem).isAllowed }
    }

    /// Lineage for one item, if it arrived without any.
    ///
    /// A tile from a search result carries none, and the engine cannot see a
    /// denied artist through a song that does not know who its artist is. A
    /// lookup that fails leaves the item as it came: the verdict is then
    /// provisional, which for a *write* means a deny may fail open — and the
    /// render-time filter catches it on the way back out.
    private func withAncestry(_ item: CatalogItem) async throws -> CatalogItem {
        guard item.ancestors.isEmpty else { return item }
        guard let resolved = try? await catalog.resolveAncestry(for: [item]).first else {
            return item
        }
        return resolved
    }
}

extension CatalogItem {
    /// Case- and diacritic-insensitive substring match over what is on screen.
    fileprivate func matches(_ term: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if title.range(of: term, options: options) != nil { return true }
        return subtitle?.range(of: term, options: options) != nil
    }
}
