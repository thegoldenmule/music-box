import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

/// What a shelf draws; blocked items are kept, never dropped, for the report.
public struct LibraryResults: Sendable, Hashable {
    /// What the kid may see, in the order the shelf wants them.
    public let items: [CatalogItem]

    /// What the engine turned down, with its reason.
    public let blocked: [BlockedItem]

    /// False: a provisional verdict from stored copies; the recheck makes it safe.
    public let isResolved: Bool

    /// Rows not yet judged; zero means the read is complete, not merely paused.
    public let pending: Int

    public init(
        items: [CatalogItem],
        blocked: [BlockedItem],
        isResolved: Bool,
        pending: Int = 0
    ) {
        self.items = items
        self.blocked = blocked
        self.isResolved = isResolved
        self.pending = pending
    }

    public static let empty = LibraryResults(items: [], blocked: [], isResolved: true)
}

/// A kid may only keep what they may play; caller logs it, tells the kid nothing.
public struct LibraryRefused: Error, Hashable, Sendable {
    public let item: CatalogItem
    public let reason: Reason

    public init(item: CatalogItem, reason: Reason) {
        self.item = item
        self.reason = reason
    }
}

/// Reachable only if our own store fails to open — a device problem, not a crash.
public struct LibraryUnavailable: Error, Hashable, Sendable {
    public init() {}
}

/// The kid's library across every provider; callers never name one.
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

    /// `isSharedDevice` alone: false is both providers, true is CloudKit only.
    private var liveProviders: [any LibraryProvider] {
        let isShared = device.state.isSharedDevice
        return providers.filter { $0.id == .cloudKit || !isShared }
    }

    /// Read-live providers, narrower still: a read waits on onboarding's ask.
    private var readableProviders: [any LibraryProvider] {
        let hasBeenAsked = device.state.hasBeenAsked
        return liveProviders.filter { $0.id == .cloudKit || hasBeenAsked }
    }

    /// Providers written for this favorite; a missing capability skips it.
    private func writers(favoriting kind: ItemKind) -> [any LibraryProvider] {
        liveProviders.filter { $0.canFavorite(kind) }
    }

    // MARK: - Reading

    /// Every favorite the kid may see, filtered at render time, not pre-filtered.
    public func favorites() async throws -> LibraryResults {
        let rows = await mergedFavoriteRows()
        return await judge(
            rows.map { Stored(id: $0.catalogID, name: $0.displayName, artworkURL: $0.artworkURL) }
        )
    }

    /// Unfiltered favorite IDs; a blocked item never reaches a screen to ask.
    public func favoriteIDs() async -> Set<CatalogID> {
        Set(await mergedFavoriteRows().map(\.catalogID))
    }

    /// Every playlist, unfiltered — the engine has no opinion on a playlist.
    public func playlists() async -> [PlaylistRow] {
        var merged: [UUID: PlaylistRow] = [:]
        for provider in readableProviders {
            // A provider that throws contributes nothing; nothing to retry.
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

    /// Songs in order; a blocked track moves to `blocked`, for the player to skip.
    public func songs(in handle: PlaylistHandle) async throws -> LibraryResults {
        var latest = LibraryResults.empty
        for await snapshot in songsIncrementally(in: handle) { latest = snapshot }
        return latest
    }

    /// The same playlist, top-first as pages resolve — see ``judged(_:)``.
    public func songsIncrementally(
        in handle: PlaylistHandle
    ) -> AsyncStream<LibraryResults> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                guard let row = await playlist(handle) else {
                    continuation.yield(.empty)
                    continuation.finish()
                    return
                }
                let stored = row.entries.map {
                    Stored(id: $0.catalogID, name: $0.displayName, artworkURL: $0.artworkURL)
                }
                for await snapshot in judged(stored) { continuation.yield(snapshot) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Searches only the kid's own records, never the whole signed-in library.
    public func searchLibrary(_ term: String) async throws -> LibraryResults {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Filter first, match second — the artist subtitle stays searchable too.
        let judged = await judge(await mergedRows())
        return LibraryResults(
            items: LibraryBrowse.filter(judged.items, by: trimmed),
            blocked: judged.blocked,
            isResolved: judged.isResolved
        )
    }

    // MARK: - Reading, for the browser

    /// The whole library, judged once; the browser's only request.
    public func contents() async -> LibraryContents {
        var latest = LibraryContents.empty
        for await snapshot in contentsIncrementally() { latest = snapshot }
        return latest
    }

    /// The same library, paged; a final snapshot tops up lineage once.
    public func contentsIncrementally() -> AsyncStream<LibraryContents> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                let stored = await mergedRows()
                let indexed = await indexedRows()
                guard !stored.isEmpty || !indexed.isEmpty else {
                    continuation.yield(.empty)
                    continuation.finish()
                    return
                }

                var stored_ancestry: [CatalogID: LibraryAncestry] = [:]
                for row in stored where !row.ancestry.isEmpty { stored_ancestry[row.id] = row.ancestry }

                var latest = LibraryResults.empty
                for await snapshot in judged(stored) {
                    latest = snapshot
                    continuation.yield(
                        assemble(judged: snapshot, indexed: indexed, ancestry: stored_ancestry)
                    )
                }

                // Once, at the end — per-page would repeat the artist's name.
                let ancestry = await toppedUpAncestry(for: stored, judged: latest)
                continuation.yield(assemble(judged: latest, indexed: indexed, ancestry: ancestry))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The browser's value; runs per page, so it must stay free of I/O.
    private func assemble(
        judged: LibraryResults,
        indexed: [LibraryIndexRow],
        ancestry: [CatalogID: LibraryAncestry]
    ) -> LibraryContents {
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
            // Unreachable: a playlist is never favorited — dropped, not asserted.
            case .playlist: break
            }
        }

        // Index comes second so a hand-kept favorite wins the resolved rating.
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
            // chosenAlbums: only what the kid pointed at directly.
            chosenAlbums: LibraryBrowse.merged(
                favoritedAlbums,
                LibraryBrowse.albums(from: songs.filter(\.isChosen))
            ),
            blocked: blocked,
            isResolved: judged.isResolved
        )
    }

    /// Everything the index holds; judged from rating and lineage at index time.
    private func indexedRows() async -> [LibraryIndexRow] {
        for provider in readableProviders {
            guard let rows = try? await provider.indexed(), !rows.isEmpty else { continue }
            return rows
        }
        return []
    }

    // MARK: - Walking down

    /// Indexes underneath a kept item, started after the write returns.
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

    /// Whether already walked, so a caller skips fifty redundant requests.
    public func isIndexed(_ id: CatalogID) async -> Bool {
        for provider in readableProviders where await provider.isIndexed(id) { return true }
        return false
    }

    // MARK: - Reading, for the admin

    /// Unfiltered, verdicts attached — unresolved reads as unknown, not blocked.
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
                // Swallowed for the kid — a short shelf looks like a broken read.
                health[provider.id] = .failed(String(describing: error))
            }
        }

        let favorites = favoriteRows.values.sorted { $0.favoritedAt > $1.favoritedAt }
        let playlists = playlistRows.values.sorted { $0.modifiedAt > $1.modifiedAt }

        // One batch for favorites and playlist entries — lineage before judgement.
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

    /// Judges a row on what came back; a library row has no rating fallback.
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

    /// A favorite is never a permission: only what a kid may currently play.
    public func addFavorite(_ item: CatalogItem, origin: LibraryOrigin = .kid) async throws {
        let resolved = try await withAncestry(item)
        if case .blocked(let reason) = engine.evaluate(resolved.policyItem) {
            throw LibraryRefused(item: resolved, reason: reason)
        }

        // Named now, while the kid already waits on a call — no later open pays.
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

    /// Unmarking is never refused — it would strand a since-denied favorite.
    public func removeFavorite(_ id: CatalogID) async throws {
        for provider in liveProviders where provider.canFavorite(id.kind) {
            try await write(to: provider) { try await $0.removeFavorite(id) }
        }
    }

    /// Makes a playlist from what survives; blocked songs drop, not refuse.
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
                // Ours is the handle callers keep: `local` is stable and survives.
                if $0.id == .cloudKit { created = row }
            }
        }

        guard let created else { throw LibraryUnavailable() }
        return created
    }

    /// Playlist entries are always songs; an album or artist is silently skipped.
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

    /// Never edits a playlist we did not create — `appleIsOurs` decides.
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

    /// Our store is awaited; other providers are dropped, the union hides the gap.
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

    /// Favorites unioned by id — a failed Apple write costs nothing visible.
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

        /// Copied at write time so artist and album columns fold with no request.
        var ancestry: LibraryAncestry = .none

        /// Write-time copy; what a shelf draws when the catalog can't answer.
        var fallback: CatalogItem {
            CatalogItem(id: id, title: name, artworkURL: artworkURL)
        }
    }

    /// Every library row deduped; favorites first, so their artwork wins.
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

    /// Resolves and judges rows; an unreachable catalog judges bare identifiers.
    private func judge(_ stored: [Stored]) async -> LibraryResults {
        // Last snapshot of the paged read, so batched and progressive can't drift.
        var latest = LibraryResults.empty
        for await snapshot in judged(stored) { latest = snapshot }
        return latest
    }

    /// Paged, top first, a growing prefix — an early page waits, never reorders.
    private func judged(_ stored: [Stored]) -> AsyncStream<LibraryResults> {
        AsyncStream { continuation in
            guard !stored.isEmpty else {
                continuation.yield(.empty)
                continuation.finish()
                return
            }

            let task = Task { @MainActor in
                let pages = CatalogFetchLimit.batches(stored, of: CatalogFetchLimit.pageSize)
                var arrived = [Bool](repeating: false, count: pages.count)
                var resolved: [CatalogID: CatalogItem] = [:]
                var isResolved = true
                var settled = 0
                var judgedRows = 0

                await withTaskGroup(of: (Int, [CatalogItem]?).self) { group in
                    var next = 0
                    func start() {
                        guard next < pages.count else { return }
                        let index = next
                        let page = pages[index]
                        next += 1
                        group.addTask { (index, await self.resolvePage(page)) }
                    }
                    for _ in 0..<min(CatalogFetchLimit.inFlight, pages.count) { start() }

                    while let (index, items) = await group.next() {
                        arrived[index] = true
                        if let items {
                            for item in items { resolved[item.id] = item }
                        } else {
                            isResolved = false
                        }
                        start()

                        // Advances the settled prefix — maybe nowhere yet.
                        var grew = false
                        while settled < pages.count, arrived[settled] {
                            judgedRows += pages[settled].count
                            settled += 1
                            grew = true
                        }
                        guard grew else { continue }

                        continuation.yield(
                            Self.verdicts(
                                over: Array(stored.prefix(judgedRows)),
                                resolved: resolved,
                                engine: engine,
                                isResolved: isResolved,
                                pending: stored.count - judgedRows
                            )
                        )
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One page: lookup then lineage; `nil`, not a throw, so failure isn't fatal.
    private func resolvePage(_ page: [Stored]) async -> [CatalogItem]? {
        do {
            let items = try await catalog.items(for: page.map(\.id))
            return try await catalog.resolveAncestry(for: items)
        } catch {
            return nil
        }
    }

    /// The engine's answer per row; static and pure, so paging can't change it.
    private static func verdicts(
        over stored: [Stored],
        resolved: [CatalogID: CatalogItem],
        engine: PolicyEngine,
        isResolved: Bool,
        pending: Int
    ) -> LibraryResults {
        var allowed: [CatalogItem] = []
        var blocked: [BlockedItem] = []
        for row in stored {
            // A resolved item is judged fully; one that isn't, by id alone.
            let item = resolved[row.id] ?? row.fallback
            switch engine.evaluate(item.policyItem) {
            case .allowed:
                allowed.append(item)
            case .blocked(let reason):
                blocked.append(BlockedItem(item: item, reason: reason))
            }
        }
        return LibraryResults(
            items: allowed, blocked: blocked, isResolved: isResolved, pending: pending
        )
    }

    /// What the kid may play in this batch; one naming request, not per song.
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

    /// Lineage for an item with none; a failed lookup lets a deny fail open.
    private func withAncestry(_ item: CatalogItem) async throws -> CatalogItem {
        guard item.ancestors.isEmpty else { return item }
        guard let resolved = try? await catalog.resolveAncestry(for: [item]).first else {
            return item
        }
        return resolved
    }

    // MARK: - Naming lineage

    /// Names lineage once, at the keep; a failed lookup still lets it land.
    private func ancestry(for item: CatalogItem) async -> LibraryAncestry {
        let ids = item.ancestors.map(\.id).filter { $0.kind == .album || $0.kind == .artist }
        guard !ids.isEmpty else { return .none }
        return Self.ancestry(from: ids, naming: await named(ids))
    }

    /// Tops up missing lineage; an artist favorite must never look unfilled.
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

    /// An identifier is recorded only with its name, or it's never topped up.
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
