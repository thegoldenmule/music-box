import CatalogKit
import CryptoKit
import FamilyStore
import Foundation
import PolicyEngine

/// Why the Apple library contributed nothing; anything else is passed through.
public enum AppleLibraryUnavailable: Error, Hashable, Sendable {
    /// iCloud Music Library is off for this account — a setting, not a fault.
    case cloudLibraryOff
}

/// How much of a library one read takes. Constants until a real one is measured.
public struct AppleLibraryLimits: Sendable, Hashable {
    /// Per request; the ISRC and UPC lookups cap at 300 and 100 identifiers.
    public var songPage = 300
    public var albumPage = 100

    /// Newest first, so the cap keeps what the account added last.
    public var songs = 500
    public var albums = 200

    /// The account holder's own playlists; each costs a request for its tracks.
    public var playlists = 25

    /// How long a snapshot is served before a read is started behind it.
    public var freshFor: TimeInterval = 10 * 60

    /// How soon a failed read is tried again — not the full ten minutes.
    public var retryAfter: TimeInterval = 60

    public init() {}
}

/// What the last completed read found; the admin's numbers.
public struct AppleLibraryRead: Sendable, Hashable {
    public let at: Date
    public let songs: Int
    public let albums: Int
    public let playlists: Int

    /// Library rows with no catalog match — research question 2, measured.
    public let unresolved: Int
}

/// The account's own library, read and never written; live only if it's the kid's.
///
/// A snapshot, not a query: `favorites()` is on the home screen's critical
/// path and runs on every heart tap, so it returns what the last read found
/// and starts the next read behind it when that's gone stale. The app awaits
/// `refresh()` on launch and foreground and reloads the shelf after.
///
/// Nothing here is stored. A row lives exactly as long as the account keeps
/// the item, and the shelf empties if the library becomes unreadable.
@MainActor
public final class AppleMusicLibraryProvider: LibraryProvider {
    public nonisolated let id = LibraryProviderID.appleMusic

    /// Read-only, so every write path in the merge sits this provider out.
    public nonisolated let capabilities: LibraryCapabilities = []

    private let source: any LibrarySource
    private let access: any CatalogAccess
    private let cache: (any ItemCache)?
    private let limits: AppleLibraryLimits
    private let now: @Sendable () -> Date

    private var favoriteRows: [FavoriteRow] = []
    private var playlistRows: [PlaylistRow] = []

    /// Lineage the merge named after the fact, kept so it's named once.
    private var learned: [CatalogID: LibraryAncestry] = [:]

    private var refreshing: Task<Void, any Error>?
    private var attemptedAt: Date?

    /// The last read that finished; nil until one has.
    public private(set) var lastRead: AppleLibraryRead?

    /// Why the last attempt failed; nil once one succeeds.
    public private(set) var lastFailure: (any Error)?

    /// - Parameter cache: where matched items go, so the shelf's own lookup
    ///   finds them warm instead of paying a request per page of rows.
    public init(
        source: any LibrarySource,
        access: any CatalogAccess,
        cache: (any ItemCache)? = nil,
        limits: AppleLibraryLimits = AppleLibraryLimits(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.access = access
        self.cache = cache
        self.limits = limits
        self.now = now
    }

    // MARK: - Reading

    /// The snapshot; throws only when there's nothing to serve and a reason why.
    public func favorites() async throws -> [FavoriteRow] {
        try serve()
        return favoriteRows
    }

    public func playlists() async throws -> [PlaylistRow] {
        try serve()
        return playlistRows
    }

    private func serve() throws {
        refreshIfStale()
        if lastRead == nil, let failure = lastFailure { throw failure }
    }

    /// Reads now, once; a read already running is joined rather than doubled.
    public func refresh() async throws {
        try await startRefresh().value
    }

    private var isStale: Bool {
        guard let attemptedAt else { return true }
        let age = now().timeIntervalSince(attemptedAt)
        return age > (lastFailure == nil ? limits.freshFor : limits.retryAfter)
    }

    private func refreshIfStale() {
        guard isStale else { return }
        _ = startRefresh()
    }

    private func startRefresh() -> Task<Void, any Error> {
        if let refreshing { return refreshing }
        attemptedAt = now()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshing = nil }
            try await self.read()
        }
        refreshing = task
        return task
    }

    private func read() async throws {
        do {
            let state = try await access.subscriptionState()
            guard state.hasCloudLibraryEnabled else { throw AppleLibraryUnavailable.cloudLibraryOff }

            let songs = try await read(.song, page: limits.songPage, cap: limits.songs)
            let albums = try await read(.album, page: limits.albumPage, cap: limits.albums)
            let playlists = try await readPlaylists()

            favoriteRows = (songs.rows + albums.rows).sorted { $0.favoritedAt > $1.favoritedAt }
            playlistRows = playlists.rows
            lastRead = AppleLibraryRead(
                at: now(),
                songs: songs.rows.count,
                albums: albums.rows.count,
                playlists: playlists.rows.count,
                unresolved: songs.unresolved + albums.unresolved + playlists.unresolved
            )
            lastFailure = nil
        } catch {
            lastFailure = error
            throw error
        }
    }

    /// Pages by offset up to the cap; a short page is the end of the library.
    private func read(
        _ kind: ItemKind,
        page: Int,
        cap: Int
    ) async throws -> (rows: [FavoriteRow], unresolved: Int) {
        var rows: [FavoriteRow] = []
        var unresolved = 0
        var offset = 0
        while offset < cap {
            let wanted = min(page, cap - offset)
            let items = try await source.libraryItems(kinds: [kind], limit: wanted, offset: offset)
            guard !items.isEmpty else { break }

            let matched = try await source.resolveToCatalog(items)
            await cache?.store(Array(matched.matches.values))
            for item in items {
                guard let match = matched.matches[item.id] else {
                    unresolved += 1
                    continue
                }
                rows.append(row(for: item, matching: match))
            }

            if items.count < wanted { break }
            offset += items.count
        }
        return (rows, unresolved)
    }

    /// The account holder's own playlists, snapshotted track by track.
    ///
    /// Apple's — mixes, stations' playlists, anything with a `kind` — are left
    /// out: they are recommendations wearing a playlist's clothes, and the
    /// catalogue they reach is nobody's choice. A playlist has no code, so the
    /// same handle on every read comes from its library id, hashed; without
    /// that the merge would see a new playlist each time. Not ours, ever —
    /// `appleIsOurs` is written only at creation, and this app created none.
    private func readPlaylists() async throws -> (rows: [PlaylistRow], unresolved: Int) {
        var rows: [PlaylistRow] = []
        var unresolved = 0
        let playlists = try await source.libraryPlaylists(limit: limits.playlists)
        for playlist in playlists where playlist.isPersonal {
            let tracks = try await source.tracks(of: playlist)
            let matched = try await source.resolveToCatalog(tracks)
            await cache?.store(Array(matched.matches.values))

            var entries: [PlaylistEntryRow] = []
            for track in tracks {
                guard let match = matched.matches[track.id] else {
                    unresolved += 1
                    continue
                }
                // Position, not the track: the same song twice is two rows.
                entries.append(
                    PlaylistEntryRow(
                        id: Self.stableID(for: "\(playlist.id)#\(entries.count)"),
                        catalogID: match.id,
                        displayName: match.title,
                        artworkURL: match.artworkURL ?? track.artworkURL,
                        position: entries.count,
                        addedAt: track.addedAt ?? .distantPast,
                        ancestry: learned[match.id] ?? Self.ancestry(of: match, named: track)
                    )
                )
            }
            rows.append(
                PlaylistRow(
                    handle: PlaylistHandle(
                        local: Self.stableID(for: "playlist:\(playlist.id)"),
                        appleLibraryID: playlist.id
                    ),
                    name: playlist.name,
                    // The library gives no dates for a playlist; none are invented.
                    createdAt: .distantPast,
                    modifiedAt: .distantPast,
                    appleIsOurs: false,
                    origin: .appleLibrary,
                    entries: entries
                )
            )
        }
        return (rows, unresolved)
    }

    private func row(for item: LibraryItem, matching match: CatalogItem) -> FavoriteRow {
        FavoriteRow(
            id: Self.stableID(for: item.id),
            catalogID: match.id,
            displayName: match.title,
            artworkURL: match.artworkURL ?? item.artworkURL,
            favoritedAt: item.addedAt ?? .distantPast,
            origin: .appleLibrary,
            ancestry: learned[match.id] ?? Self.ancestry(of: match, named: item)
        )
    }

    /// Ids from the match, names from the library side — no request to name them.
    ///
    /// Filled here so the merge's top-up, which names only rows with *no*
    /// lineage, leaves these alone: five hundred rows would otherwise be named
    /// again on every read of the browser. Empty ids are dropped, as everywhere.
    private static func ancestry(of match: CatalogItem, named item: LibraryItem) -> LibraryAncestry {
        var out = LibraryAncestry()
        for ancestor in match.ancestors where !ancestor.id.rawValue.isEmpty {
            switch ancestor.id.kind {
            case .album where out.albumID == nil:
                out.albumID = ancestor.id.rawValue
                out.albumName = item.albumTitle
            case .artist where out.artistID == nil:
                out.artistID = ancestor.id.rawValue
                out.artistName = item.subtitle
            default:
                break
            }
        }
        return out
    }

    /// The same library row is the same row on every read — and never stored.
    nonisolated static func stableID(for libraryID: String) -> UUID {
        let digest = SHA256.hash(data: Data("appleLibrary:\(libraryID)".utf8))
        var bytes = Array(digest.prefix(16))
        // Version and variant bits, so it reads as a name-based UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }

    // MARK: - What the merge tells us

    /// Kept in memory only, on the rows and for the next read to reuse.
    public func recordAncestry(_ ancestry: [CatalogID: LibraryAncestry]) async throws {
        guard !ancestry.isEmpty else { return }
        learned.merge(ancestry) { _, new in new }
        favoriteRows = favoriteRows.map { row in
            guard let found = ancestry[row.catalogID] else { return row }
            return FavoriteRow(
                id: row.id,
                catalogID: row.catalogID,
                displayName: row.displayName,
                artworkURL: row.artworkURL,
                favoritedAt: row.favoritedAt,
                origin: row.origin,
                ancestry: found
            )
        }
    }

    // MARK: - Writes: none

    public func addFavorite(
        _ id: CatalogID,
        displayName: String,
        artworkURL: URL?,
        origin: LibraryOrigin,
        ancestry: LibraryAncestry
    ) async throws {}

    public func removeFavorite(_ id: CatalogID) async throws {}

    public func createPlaylist(named name: String, songs: [LibrarySong]) async throws -> PlaylistRow {
        throw LibraryUnavailable()
    }

    public func addToPlaylist(_ handle: PlaylistHandle, song: LibrarySong) async throws {}
    public func removeFromPlaylist(_ handle: PlaylistHandle, song: CatalogID) async throws {}
    public func reorderPlaylist(_ handle: PlaylistHandle, to order: [CatalogID]) async throws {}
    public func renamePlaylist(_ handle: PlaylistHandle, to name: String) async throws {}
    public func deletePlaylist(_ handle: PlaylistHandle) async throws {}
}
