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

        // Filter first, match second. Matching on the resolved item means the
        // subtitle — the artist name — is searchable, which is most of what a kid
        // types, and the copied `displayName` is only ever the title.
        let judged = await judge(await mergedRows())
        return LibraryResults(
            items: LibraryBrowse.filter(judged.items, by: trimmed),
            blocked: judged.blocked,
            isResolved: judged.isResolved
        )
    }

    // MARK: - Reading, for the browser

    /// The whole library, resolved and judged once, ready to be filtered.
    ///
    /// **The browser's only request.** Everything the four columns and their
    /// drill-ins show is computed from this one value, which is what makes
    /// filtering as a child types synchronous and tapping an artist instant.
    ///
    /// Three passes over the catalog at most, and usually one: the batch that
    /// resolves the rows, the batch that names any ancestors the rows do not
    /// already carry, and the write that records those names so the second batch
    /// does not happen again. Steady state is the first alone.
    public func contents() async -> LibraryContents {
        let stored = await mergedRows()
        let indexed = await indexedRows()
        guard !stored.isEmpty || !indexed.isEmpty else { return .empty }

        let judged = await judge(stored)
        let ancestry = await toppedUpAncestry(for: stored, judged: judged)

        var songs: [LibrarySong] = []
        var favoritedAlbums: [CatalogItem] = []
        var favoritedArtists: [CatalogItem] = []
        var blocked = judged.blocked
        var seen: Set<CatalogID> = []
        for item in judged.items where seen.insert(item.id).inserted {
            switch item.id.kind {
            case .song: songs.append(LibrarySong(item: item, ancestry: ancestry[item.id] ?? .none))
            case .album: favoritedAlbums.append(item)
            case .artist: favoritedArtists.append(item)
            // Not reachable: a playlist is owned, never favorited, and never a
            // playlist entry. Dropped rather than asserted on — an unreadable row
            // costs a tile and costs safety nothing.
            case .playlist: break
            }
        }

        // The index comes second so that anything the kid kept **by hand** wins
        // the duplicate. A song they hearted and that also arrived under its
        // artist is one row, and it is the resolved one — which carries the
        // catalog's rating rather than the copy taken when the walk ran.
        var indexedAlbums: [CatalogItem] = []
        for row in indexed where seen.insert(row.catalogID).inserted {
            switch engine.evaluate(row.policyItem) {
            case .allowed:
                switch row.catalogID.kind {
                case .song:
                    songs.append(
                        LibrarySong(item: row.item, ancestry: row.ancestry, isChosen: false)
                    )
                case .album: indexedAlbums.append(row.item)
                default: break
                }
            case .blocked(let reason):
                blocked.append(BlockedItem(item: row.item, reason: reason))
            }
        }

        return LibraryContents(
            songs: songs,
            artists: LibraryBrowse.merged(favoritedArtists, LibraryBrowse.artists(from: songs)),
            albums: LibraryBrowse.merged(
                favoritedAlbums,
                indexedAlbums,
                LibraryBrowse.albums(from: songs)
            ),
            // Neither the records a walk brought in nor the ones folded out of
            // the tracks it brought with them. What is left is what the kid
            // pointed at: a record they hearted, or one a song they hearted sits
            // on.
            chosenAlbums: LibraryBrowse.merged(
                favoritedAlbums,
                LibraryBrowse.albums(from: songs.filter(\.isChosen))
            ),
            blocked: blocked,
            isResolved: judged.isResolved
        )
    }

    /// Everything the index holds, from whichever provider keeps it.
    ///
    /// **Judged locally and never resolved.** This table is unbounded — one
    /// hearted artist can be a thousand songs — and putting a thousand-item
    /// request in front of the library would undo the whole reason the walk
    /// happens at insert. Every row carries the rating and the lineage the
    /// catalog gave at index time, which is everything a verdict needs.
    private func indexedRows() async -> [LibraryIndexRow] {
        for provider in readableProviders {
            guard let rows = try? await provider.indexed(), !rows.isEmpty else { continue }
            return rows
        }
        return []
    }

    // MARK: - Walking down

    /// Indexes everything underneath something the kid just kept.
    ///
    /// **Long, and deliberately not part of the write.** ``addFavorite(_:origin:)``
    /// returns as soon as the heart is safe; this is what the caller starts
    /// afterwards and does not wait for. An artist is fifty round trips and the
    /// app stays usable throughout — each step is saved as it lands, so what is
    /// already indexed is browsable while the rest arrives.
    ///
    /// Idempotent by identifier within a source, so a walk re-run after being
    /// interrupted adds what is missing rather than duplicating what is there.
    ///
    /// Failure is silent on purpose. Nothing here is something the kid asked for
    /// by name — they hearted an artist and that worked — so there is no message
    /// to show and nothing for them to do about it. The next heart of the same
    /// thing walks again.
    public func expand(_ item: CatalogItem) async {
        guard item.id.kind == .album || item.id.kind == .artist else { return }

        let walk = LibraryWalk(catalog: catalog)
        let writers = liveProviders
        try? await walk.walk(item) { batch in
            for provider in writers {
                try? await provider.appendIndex(from: batch.source, rows: batch.rows)
            }
        }
    }

    /// Whether this favorite has already been walked by the current walk.
    ///
    /// What a caller checks before spending fifty requests re-deriving something
    /// it already has.
    public func isIndexed(_ id: CatalogID) async -> Bool {
        for provider in readableProviders where await provider.isIndexed(id) { return true }
        return false
    }

    // MARK: - Reading, for the admin

    /// The whole shelf, unfiltered, with today's verdict on every row.
    ///
    /// **The one read on this type that keeps what the engine turns down.**
    /// Everywhere else in this file a blocked row is separated out so a screen
    /// can drop it; here it stays in place with its verdict attached, because
    /// the parent's report is the surface that exists to show it. There is no
    /// variant of this method that filters.
    ///
    /// Resolution is best-effort and never a precondition for drawing. Offline,
    /// every row still renders from the copies made at write time — and every
    /// verdict that would have turned on a rating we do not hold comes back as
    /// ``AncestryConfidence/unknown`` rather than as a confident block, because
    /// a report full of "they can't play this any more" that is really "we did
    /// not ask" is worse than a report that says less.
    ///
    /// Never reachable from a kid screen: see ``ProviderHealth``, which is
    /// admin-facing by construction.
    public func reviewed() async -> ReviewedLibrary {
        var health: [LibraryProviderID: ProviderHealth] = [:]
        let live = Set(liveProviders.map(\.id))
        let readable = Set(readableProviders.map(\.id))
        for provider in providers {
            if !live.contains(provider.id) {
                health[provider.id] = .notConfigured(.sharedDevice)
            } else if !readable.contains(provider.id) {
                health[provider.id] = .notConfigured(.notYetAsked)
            } else {
                health[provider.id] = .live
            }
        }

        var favoriteRows: [CatalogID: FavoriteRow] = [:]
        var playlistRows: [UUID: PlaylistRow] = [:]
        for provider in readableProviders {
            do {
                for row in try await provider.favorites() where favoriteRows[row.catalogID] == nil {
                    favoriteRows[row.catalogID] = row
                }
                for row in try await provider.playlists() where playlistRows[row.handle.local] == nil
                {
                    playlistRows[row.handle.local] = row
                }
            } catch {
                // The kid's side swallows this; the admin is told. A short shelf
                // and a broken read look identical and only one is about the
                // child.
                health[provider.id] = .failed(String(describing: error))
            }
        }

        let favorites = favoriteRows.values.sorted { $0.favoritedAt > $1.favoritedAt }
        let playlists = playlistRows.values.sorted { $0.modifiedAt > $1.modifiedAt }

        // One batch for everything on the screen, favorites and playlist entries
        // together — lineage before judgement, as everywhere else.
        var wanted: [CatalogID] = favorites.map(\.catalogID)
        var seen = Set(wanted)
        for playlist in playlists {
            for entry in playlist.entries where seen.insert(entry.catalogID).inserted {
                wanted.append(entry.catalogID)
            }
        }

        var resolved: [CatalogID: CatalogItem] = [:]
        var isResolved = true
        if !wanted.isEmpty {
            do {
                let items = try await catalog.items(for: wanted)
                for item in try await catalog.resolveAncestry(for: items) {
                    resolved[item.id] = item
                }
            } catch {
                isResolved = false
            }
        }

        return ReviewedLibrary(
            favorites: favorites.map { annotate($0, $0.catalogID, resolved) },
            playlists: playlists.map { row in
                ReviewedPlaylist(
                    row: row,
                    entries: row.entries.map { annotate($0, $0.catalogID, resolved) }
                )
            },
            providers: health,
            unresolved: wanted.count { resolved[$0] == nil },
            isResolved: isResolved
        )
    }

    /// Judges one stored row on whatever the catalog gave back for it.
    ///
    /// A row that resolved carries a real rating and real lineage, so its
    /// verdict is exact. One that did not carries neither — and a library row,
    /// unlike an event row, has no rating column to fall back on, which is the
    /// whole reason ``AncestryConfidence/unknown`` exists.
    private func annotate<Row: Sendable>(
        _ row: Row,
        _ id: CatalogID,
        _ resolved: [CatalogID: CatalogItem]
    ) -> Annotated<Row> {
        guard let item = resolved[id] else {
            return ReviewAnnotator.annotate(
                row,
                knowing: ReviewAnnotator.Knowledge(
                    item: Item(id: id),
                    ancestryIsComplete: false,
                    ratingIsRecorded: false
                ),
                with: engine
            )
        }
        return ReviewAnnotator.annotate(
            row,
            knowing: ReviewAnnotator.Knowledge(
                item: item.policyItem,
                ancestryIsComplete: true,
                ratingIsRecorded: true
            ),
            with: engine
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

        // Named here rather than on the way back out: this is the one moment the
        // kid is waiting on a network call anyway, and doing it now is what keeps
        // it out of every subsequent library open.
        let lineage = await ancestry(for: resolved)

        for provider in writers(favoriting: item.id.kind) {
            try await write(to: provider) {
                try await $0.addFavorite(
                    item.id,
                    displayName: item.title,
                    artworkURL: item.artworkURL,
                    origin: origin,
                    ancestry: lineage
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

        let kept = LibrarySong(item: song, ancestry: await ancestry(for: resolved))
        try await edit(handle) { try await $0.addToPlaylist(handle, song: kept) }
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

        /// Copied at write time like the other two, and for the same reason: the
        /// artist and album columns are folded from it without a request. See
        /// ``LibraryAncestry``.
        var ancestry: LibraryAncestry = .none

        /// The copy made at write time. What a shelf draws when the catalog is
        /// not reachable — `displayName` and `artworkURL` are copied for exactly
        /// this, so a list renders offline.
        var fallback: CatalogItem {
            CatalogItem(id: id, title: name, artworkURL: artworkURL)
        }
    }

    /// Every row in the library, favorites and playlist entries together, deduped.
    ///
    /// The union ``searchLibrary(_:)`` was already building, lifted out because
    /// the browser needs the same one. Favorites lead, so the fold's
    /// first-one-wins keeps a container's artwork from the most recently hearted
    /// song on it.
    private func mergedRows() async -> [Stored] {
        var stored: [Stored] = []
        var seen: Set<CatalogID> = []
        for row in await mergedFavoriteRows() where seen.insert(row.catalogID).inserted {
            stored.append(
                Stored(
                    id: row.catalogID,
                    name: row.displayName,
                    artworkURL: row.artworkURL,
                    ancestry: row.ancestry
                )
            )
        }
        for playlist in await playlists() {
            for entry in playlist.entries where seen.insert(entry.catalogID).inserted {
                stored.append(
                    Stored(
                        id: entry.catalogID,
                        name: entry.displayName,
                        artworkURL: entry.artworkURL,
                        ancestry: entry.ancestry
                    )
                )
            }
        }
        return stored
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

    /// Everything in this batch the kid may currently play, lineage named.
    ///
    /// One naming request for the whole playlist rather than one per song — the
    /// same batch-before-judge shape everything else in this file keeps.
    private func allowedSongs(_ songs: [CatalogItem]) async throws -> [LibrarySong] {
        guard !songs.isEmpty else { return [] }
        let resolved = try await catalog.resolveAncestry(for: songs)
        let allowed = resolved.filter {
            $0.id.kind == .song && engine.evaluate($0.policyItem).isAllowed
        }

        let parents = allowed.flatMap { $0.ancestors.map(\.id) }
            .filter { $0.kind == .album || $0.kind == .artist }
        let names = await named(Array(Set(parents)))

        return allowed.map {
            LibrarySong(
                item: $0,
                ancestry: Self.ancestry(from: $0.ancestors.map(\.id), naming: names)
            )
        }
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

    // MARK: - Naming lineage

    /// The lineage to write down beside an item, names and all.
    ///
    /// `Ancestor` carries `{id, rating}` and no title, so naming the parents is a
    /// second lookup — one that happens **here, at the moment the kid keeps
    /// something**, rather than every time they open their library. That is the
    /// whole trade ``LibraryAncestry`` exists to make.
    ///
    /// A failure returns nothing and the write still happens. A heart must not
    /// fail because the network did; ``toppedUpAncestry(for:judged:)`` fills the
    /// gap on a later read.
    private func ancestry(for item: CatalogItem) async -> LibraryAncestry {
        let ids = item.ancestors.map(\.id).filter { $0.kind == .album || $0.kind == .artist }
        guard !ids.isEmpty else { return .none }
        return Self.ancestry(from: ids, naming: await named(ids))
    }

    /// Lineage for every row on this pass, topping up whatever has none.
    ///
    /// **Only rows the catalog answered for are candidates.** An artist favorite
    /// has no ancestors and must never look like a row waiting to be filled, or
    /// every read would ask about it again forever.
    ///
    /// The write back is deliberately not the kid's: it carries no new fact about
    /// them, so a provider that cannot store it declines by default and one that
    /// fails is simply asked again next time.
    private func toppedUpAncestry(
        for stored: [Stored],
        judged: LibraryResults
    ) async -> [CatalogID: LibraryAncestry] {
        var out: [CatalogID: LibraryAncestry] = [:]
        for row in stored where !row.ancestry.isEmpty { out[row.id] = row.ancestry }

        let resolved = Dictionary(judged.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var parents: [CatalogID: [CatalogID]] = [:]
        var wanted: Set<CatalogID> = []
        for row in stored where row.ancestry.isEmpty {
            guard let item = resolved[row.id] else { continue }
            let ids = item.ancestors.map(\.id).filter { $0.kind == .album || $0.kind == .artist }
            guard !ids.isEmpty else { continue }
            parents[row.id] = ids
            wanted.formUnion(ids)
        }
        guard !wanted.isEmpty else { return out }

        let names = await named(Array(wanted))
        var learned: [CatalogID: LibraryAncestry] = [:]
        for (id, ids) in parents {
            let built = Self.ancestry(from: ids, naming: names)
            guard !built.isEmpty else { continue }
            learned[id] = built
            out[id] = built
        }

        guard !learned.isEmpty else { return out }
        for provider in liveProviders {
            try? await provider.recordAncestry(learned)
        }
        return out
    }

    /// Resolves identifiers to items purely to read their titles.
    private func named(_ ids: [CatalogID]) async -> [CatalogID: CatalogItem] {
        guard !ids.isEmpty, let items = try? await catalog.items(for: ids) else { return [:] }
        return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// **An identifier is only recorded together with its name.**
    ///
    /// A lineage of bare identifiers would satisfy ``LibraryAncestry/isEmpty`` and
    /// so never be topped up again, while the fold — which needs a name to draw a
    /// row — would skip it. The column would be permanently short and nothing
    /// would ever try to fix it.
    ///
    /// Nearest first, so the first album and the first artist win. That is the
    /// order `resolveAncestry` builds and the order the engine reads for
    /// ``UnratedBehavior/inheritFromAncestor``; relying on kind rather than
    /// position keeps this correct if that ever changes.
    private static func ancestry(
        from ids: [CatalogID],
        naming names: [CatalogID: CatalogItem]
    ) -> LibraryAncestry {
        var out = LibraryAncestry()
        for id in ids {
            guard let named = names[id] else { continue }
            switch id.kind {
            case .album where out.albumID == nil:
                out.albumID = id.rawValue
                out.albumName = named.title
            case .artist where out.artistID == nil:
                out.artistID = id.rawValue
                out.artistName = named.title
                out.artistArtworkURL = named.artworkURL
            default:
                break
            }
        }
        return out
    }
}
