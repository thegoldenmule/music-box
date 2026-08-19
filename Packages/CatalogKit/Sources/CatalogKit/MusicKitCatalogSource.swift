#if canImport(MusicKit)

import Foundation
import MusicKit
import PolicyEngine

/// Only file importing MusicKit; behavior lives in ``FilteredCatalog``, not here.
public struct MusicKitCatalogSource: CatalogSource {
    /// Artwork stays URL-only; MusicKit's terms forbid copying it into storage.
    private let artworkSize: Int

    /// Search's hard cap, 25 — verified on device the hard way: 75 was a 400.
    public static let maxSearchLimit = 25

    public init(artworkSize: Int = 512) {
        self.artworkSize = artworkSize
    }

    // MARK: - Search

    public func search(
        term: String,
        kinds: Set<ItemKind>,
        limit: Int,
        offset: Int
    ) async throws -> CatalogPage {
        var types: [any MusicCatalogSearchable.Type] = []
        if kinds.contains(.artist) { types.append(Artist.self) }
        if kinds.contains(.album) { types.append(Album.self) }
        if kinds.contains(.song) { types.append(Song.self) }
        if kinds.contains(.playlist) { types.append(Playlist.self) }
        guard !types.isEmpty else { return .empty }

        // Clamped: over-asking shortens the page; hasMore reads against the clamp.
        let effectiveLimit = min(limit, Self.maxSearchLimit)

        var request = MusicCatalogSearchRequest(term: term, types: types)
        request.limit = effectiveLimit
        request.offset = offset

        let response = try await mapErrors { try await request.response() }

        var items: [CatalogItem] = []
        items += response.songs.map(item(from:))
        items += response.albums.map(item(from:))
        items += response.artists.map(item(from:))
        items += response.playlists.map(item(from:))

        // No total count: a full page infers more; one extra request beats a miss.
        return CatalogPage(items: items, hasMore: items.count >= effectiveLimit)
    }

    // MARK: - Lookup

    public func item(for id: CatalogID) async throws -> CatalogItem? {
        let musicID = MusicItemID(id.rawValue)

        switch id.kind {
        case .song:
            return try await fetchSong(musicID).map(item(from:))
        case .album:
            return try await fetchAlbum(musicID).map(item(from:))
        case .artist:
            return try await fetchArtist(musicID).map(item(from:))
        case .playlist:
            return try await fetchPlaylist(musicID).map(item(from:))
        }
    }

    private func fetchSong(_ id: MusicItemID) async throws -> Song? {
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
        return try await mapErrors { try await request.response() }.items.first
    }

    private func fetchAlbum(_ id: MusicItemID) async throws -> Album? {
        let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: id)
        return try await mapErrors { try await request.response() }.items.first
    }

    private func fetchArtist(_ id: MusicItemID) async throws -> Artist? {
        let request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: id)
        return try await mapErrors { try await request.response() }.items.first
    }

    private func fetchPlaylist(_ id: MusicItemID) async throws -> Playlist? {
        let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id)
        return try await mapErrors { try await request.response() }.items.first
    }

    /// One request per kind (typed API); missing ids drop as delistings.
    public func items(for ids: [CatalogID]) async throws -> [CatalogItem] {
        var found: [CatalogID: CatalogItem] = [:]

        for kind in ItemKind.allCases {
            let musicIDs = ids.filter { $0.kind == kind && !$0.rawValue.isEmpty }
                .map { MusicItemID($0.rawValue) }
            guard !musicIDs.isEmpty else { continue }

            for item in try await items(ofKind: kind, ids: musicIDs) {
                found[item.id] = item
            }
        }

        // The caller's order is the meaningful one — recents are in time order.
        return ids.compactMap { found[$0] }
    }

    /// Sequential batches (``CatalogFetchLimit``); one failure fails the call.
    private func items(ofKind kind: ItemKind, ids: [MusicItemID]) async throws -> [CatalogItem] {
        var found: [CatalogItem] = []
        for batch in CatalogFetchLimit.batches(ids, for: kind) {
            found += try await fetch(ofKind: kind, ids: batch)
        }
        return found
    }

    /// One request. The caller has already made `ids` short enough to send.
    private func fetch(ofKind kind: ItemKind, ids: [MusicItemID]) async throws -> [CatalogItem] {
        switch kind {
        case .song:
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids)
            request.properties = [.albums, .artists]
            return try await mapErrors { try await request.response() }.items.map(item(from:))
        case .album:
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, memberOf: ids)
            request.properties = [.artists]
            return try await mapErrors { try await request.response() }.items.map(item(from:))
        case .artist:
            let request = MusicCatalogResourceRequest<Artist>(matching: \.id, memberOf: ids)
            return try await mapErrors { try await request.response() }.items.map(item(from:))
        case .playlist:
            let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, memberOf: ids)
            return try await mapErrors { try await request.response() }.items.map(item(from:))
        }
    }

    // MARK: - Children

    public func children(of id: CatalogID) async throws -> [CatalogItem] {
        let musicID = MusicItemID(id.rawValue)

        switch id.kind {
        case .artist:
            guard let artist = try await fetchArtist(musicID) else { return [] }
            let detailed = try await mapErrors { try await artist.with([.albums]) }
            return (detailed.albums ?? []).map(item(from:))

        case .album:
            guard let album = try await fetchAlbum(musicID) else { return [] }
            let detailed = try await mapErrors { try await album.with([.tracks]) }
            return (detailed.tracks ?? []).compactMap(item(from:))

        case .playlist:
            guard let playlist = try await fetchPlaylist(musicID) else { return [] }
            let detailed = try await mapErrors { try await playlist.with([.tracks]) }
            return (detailed.tracks ?? []).compactMap(item(from:))

        case .song:
            return []
        }
    }

    /// A property does this in one request; children(of:) still needs two.
    public func topSongs(of id: CatalogID) async throws -> [CatalogItem] {
        guard id.kind == .artist, !id.rawValue.isEmpty else { return [] }

        var request = MusicCatalogResourceRequest<Artist>(
            matching: \.id,
            equalTo: MusicItemID(id.rawValue)
        )
        request.properties = [.topSongs]

        let response = try await mapErrors { try await request.response() }
        guard let artist = response.items.first else { return [] }
        return (artist.topSongs ?? []).map(item(from:))
    }

    // MARK: - Credits

    /// Every credited artist, not just the first — ancestry only needs one.
    public func artists(of id: CatalogID) async throws -> [CatalogItem] {
        let musicID = MusicItemID(id.rawValue)

        switch id.kind {
        case .album:
            guard let album = try await fetchAlbum(musicID) else { return [] }
            let detailed = try await mapErrors { try await album.with([.artists]) }
            return (detailed.artists ?? []).map(item(from:)).filter { !$0.id.rawValue.isEmpty }

        case .song:
            guard let song = try await fetchSong(musicID) else { return [] }
            let detailed = try await mapErrors { try await song.with([.artists]) }
            return (detailed.artists ?? []).map(item(from:)).filter { !$0.id.rawValue.isEmpty }

        case .artist, .playlist:
            return []
        }
    }

    // MARK: - Ancestry

    /// Batched: search results arrive with no relationships to judge against.
    public func resolveAncestry(for items: [CatalogItem]) async throws -> [CatalogItem] {
        // Empty ids are dropped, not sent; a bad match leaves lineage provisional.
        let songIDs = items
            .filter { $0.id.kind == .song && $0.ancestors.isEmpty && !$0.id.rawValue.isEmpty }
            .map { MusicItemID($0.id.rawValue) }
        let albumIDs = items
            .filter { $0.id.kind == .album && $0.ancestors.isEmpty && !$0.id.rawValue.isEmpty }
            .map { MusicItemID($0.id.rawValue) }

        var ancestryByID: [CatalogID: [Ancestor]] = [:]

        // Split like ``items(ofKind:ids:)`` — chunking there shifts the failure.
        for batch in CatalogFetchLimit.batches(songIDs, for: .song) {
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch)
            request.properties = [.albums, .artists]
            let response = try await mapErrors { try await request.response() }
            for song in response.items {
                ancestryByID[CatalogID(.song, song.id.rawValue)] = ancestry(of: song)
            }
        }

        for batch in CatalogFetchLimit.batches(albumIDs, for: .album) {
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, memberOf: batch)
            request.properties = [.artists]
            let response = try await mapErrors { try await request.response() }
            for album in response.items {
                ancestryByID[CatalogID(.album, album.id.rawValue)] = ancestry(of: album)
            }
        }

        return items.map { item in
            guard item.ancestors.isEmpty, let ancestors = ancestryByID[item.id] else { return item }
            return item.withAncestors(ancestors)
        }
    }

    /// Empty-id ancestors drop — an empty `CatalogID` would never trigger a deny.
    private func ancestry(of song: Song) -> [Ancestor] {
        var ancestors: [Ancestor] = []
        if let album = song.albums?.first, !album.id.rawValue.isEmpty {
            ancestors.append(
                Ancestor(
                    id: CatalogID(.album, album.id.rawValue),
                    rating: rating(from: album.contentRating)
                )
            )
        }
        if let artist = song.artists?.first, !artist.id.rawValue.isEmpty {
            ancestors.append(Ancestor(id: CatalogID(.artist, artist.id.rawValue)))
        }
        return ancestors
    }

    private func ancestry(of album: Album) -> [Ancestor] {
        guard let artist = album.artists?.first, !artist.id.rawValue.isEmpty else { return [] }
        return [Ancestor(id: CatalogID(.artist, artist.id.rawValue))]
    }

    // MARK: - Mapping

    private func rating(from musicKit: MusicKit.ContentRating?) -> SandboxContentRating? {
        switch musicKit {
        case .clean: .clean
        case .explicit: .explicit
        case .none: nil
        @unknown default: nil
        }
    }

    private func artworkURL(_ artwork: Artwork?) -> URL? {
        artwork?.url(width: artworkSize, height: artworkSize)
    }

    private func item(from song: Song) -> CatalogItem {
        CatalogItem(
            id: CatalogID(.song, song.id.rawValue),
            title: song.title,
            subtitle: song.artistName,
            artworkURL: artworkURL(song.artwork),
            rating: rating(from: song.contentRating),
            // Free with the song; a later request would never get them added.
            duration: song.duration,
            trackNumber: song.trackNumber
        )
    }

    private func item(from album: Album) -> CatalogItem {
        CatalogItem(
            id: CatalogID(.album, album.id.rawValue),
            title: album.title,
            subtitle: album.artistName,
            artworkURL: artworkURL(album.artwork),
            rating: rating(from: album.contentRating),
            // Kept, not flattened — ``isSingleRelease`` decides absence.
            isSingle: album.isSingle,
            trackCount: album.trackCount
        )
    }

    private func item(from artist: Artist) -> CatalogItem {
        CatalogItem(
            id: CatalogID(.artist, artist.id.rawValue),
            title: artist.name,
            subtitle: nil,
            artworkURL: artworkURL(artist.artwork),
            // Artists carry no rating; contents are judged individually.
            rating: nil
        )
    }

    private func item(from playlist: Playlist) -> CatalogItem {
        CatalogItem(
            id: CatalogID(.playlist, playlist.id.rawValue),
            title: playlist.name,
            subtitle: playlist.curatorName,
            artworkURL: artworkURL(playlist.artwork),
            // Playlists have no `contentRating`; each track is judged as it comes.
            rating: nil
        )
    }

    private func item(from track: Track) -> CatalogItem? {
        switch track {
        case .song(let song):
            return item(from: song)
        case .musicVideo:
            // Music videos are out of scope: no player surface, no rating rule.
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - Errors

    /// Turn MusicKit's errors into ones the UI can write a sentence about.
    fileprivate func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw CatalogError.offline
            default:
                throw CatalogError.underlying(error.localizedDescription)
            }
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.underlying(error.localizedDescription)
        }
    }
}

// MARK: - Library seeding

/// Reads the library for seeding; everything is matched to the catalog first.
public struct MusicKitLibrarySource: LibrarySource {
    private let catalog: MusicKitCatalogSource
    private let artworkSize: Int

    public init(artworkSize: Int = 512) {
        self.catalog = MusicKitCatalogSource(artworkSize: artworkSize)
        self.artworkSize = artworkSize
    }

    public func libraryItems(kinds: Set<ItemKind>, limit: Int) async throws -> [LibraryItem] {
        var items: [LibraryItem] = []

        if kinds.contains(.song) {
            var request = MusicLibraryRequest<Song>()
            request.limit = limit
            let response = try await catalog.mapErrors { try await request.response() }
            items += response.items.map(libraryItem(from:))
        }
        if kinds.contains(.album) {
            var request = MusicLibraryRequest<Album>()
            request.limit = limit
            let response = try await catalog.mapErrors { try await request.response() }
            items += response.items.map(libraryItem(from:))
        }
        return items
    }

    public func searchLibrary(
        term: String,
        kinds: Set<ItemKind>,
        limit: Int
    ) async throws -> [LibraryItem] {
        var types: [any MusicLibrarySearchable.Type] = []
        if kinds.contains(.song) { types.append(Song.self) }
        if kinds.contains(.album) { types.append(Album.self) }
        guard !types.isEmpty else { return [] }

        var request = MusicLibrarySearchRequest(term: term, types: types)
        request.limit = limit
        let response = try await catalog.mapErrors { try await request.response() }

        var items: [LibraryItem] = []
        items += response.songs.map(libraryItem(from:))
        items += response.albums.map(libraryItem(from:))
        return items
    }

    // MARK: - Playlists and artists
    // Unverified: MusicKit isn't enabled on this App ID, so nothing here has run.

    public func libraryPlaylists(limit: Int) async throws -> [LibraryPlaylist] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = limit
        let response = try await catalog.mapErrors { try await request.response() }
        return response.items.map(libraryPlaylist(from:))
    }

    /// Refetched by id — `MusicItemCollection` can't cross; videos drop silently.
    public func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryItem] {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(playlist.id))
        let response = try await catalog.mapErrors { try await request.response() }
        guard let found = response.items.first else { return [] }

        let detailed = try await catalog.mapErrors { try await found.with([.tracks]) }
        guard let tracks = detailed.tracks else { return [] }

        return tracks.compactMap { track in
            guard case .song(let song) = track else { return nil }
            return libraryItem(from: song)
        }
    }

    public func libraryArtists(limit: Int) async throws -> [LibraryItem] {
        var request = MusicLibraryRequest<Artist>()
        request.limit = limit
        let response = try await catalog.mapErrors { try await request.response() }
        return response.items.map { artist in
            LibraryItem(
                id: artist.id.rawValue,
                kind: .artist,
                title: artist.name,
                artworkURL: artworkURL(artist.artwork)
            )
        }
    }

    /// Votes over songs to survive name-search over-matching; ties ask the parent.
    public func resolveArtist(_ artist: LibraryItem) async throws -> ArtistResolution {
        guard artist.kind == .artist else { return .notInAppleMusic }

        let songs = try await searchLibrary(
            term: artist.title,
            kinds: [.song],
            limit: ArtistVote.sample
        )
        guard !songs.isEmpty else { return .notInAppleMusic }

        let matched = try await resolveToCatalog(songs)
        guard !matched.resolved.isEmpty else { return .notInAppleMusic }

        guard let winner = ArtistVote.winner(among: matched.resolved) else { return .ambiguous }
        guard let item = try await catalog.item(for: winner) else { return .notInAppleMusic }
        return .resolved(item)
    }

    private func libraryPlaylist(from playlist: Playlist) -> LibraryPlaylist {
        LibraryPlaylist(
            id: playlist.id.rawValue,
            name: playlist.name,
            curatorName: playlist.curatorName,
            trackCount: playlist.tracks?.count,
            artworkURL: artworkURL(playlist.artwork),
            // No `kind` means self-made; every case names something Apple built.
            isPersonal: playlist.kind == nil
        )
    }

    /// Matches by ISRC/UPC, two batched requests regardless of selection size.
    public func resolveToCatalog(_ items: [LibraryItem]) async throws -> LibraryImport {
        var resolved: [CatalogItem] = []
        var discarded: [DiscardedItem] = []

        var songsByISRC: [String: LibraryItem] = [:]
        var albumsByUPC: [String: LibraryItem] = [:]

        for item in items {
            switch item.kind {
            case .song:
                if let isrc = item.isrc {
                    songsByISRC[isrc] = item
                } else {
                    discarded.append(DiscardedItem(item: item, reason: .noIdentifier))
                }
            case .album:
                if let upc = item.upc {
                    albumsByUPC[upc] = item
                } else {
                    discarded.append(DiscardedItem(item: item, reason: .noIdentifier))
                }
            case .artist, .playlist:
                discarded.append(DiscardedItem(item: item, reason: .unsupportedKind))
            }
        }

        var matchedISRCs: Set<String> = []
        if !songsByISRC.isEmpty {
            let codes: [String?] = songsByISRC.keys.map { $0 }
            var request = MusicCatalogResourceRequest<Song>(matching: \.isrc, memberOf: codes)
            request.properties = [.albums, .artists]
            findEquivalentsIfAvailable(&request)
            let response = try await catalog.mapErrors { try await request.response() }
            for song in response.items {
                if let isrc = song.isrc { matchedISRCs.insert(isrc) }
                resolved.append(catalogItem(from: song))
            }
        }

        var matchedUPCs: Set<String> = []
        if !albumsByUPC.isEmpty {
            let codes: [String?] = albumsByUPC.keys.map { $0 }
            var request = MusicCatalogResourceRequest<Album>(matching: \.upc, memberOf: codes)
            request.properties = [.artists]
            findEquivalentsIfAvailable(&request)
            let response = try await catalog.mapErrors { try await request.response() }
            for album in response.items {
                if let upc = album.upc { matchedUPCs.insert(upc) }
                resolved.append(catalogItem(from: album))
            }
        }

        // No match despite a code: delisted, regional, bootleg — discarded, named.
        for (isrc, item) in songsByISRC where !matchedISRCs.contains(isrc) {
            discarded.append(DiscardedItem(item: item, reason: .notInAppleMusic))
        }
        for (upc, item) in albumsByUPC where !matchedUPCs.contains(upc) {
            discarded.append(DiscardedItem(item: item, reason: .notInAppleMusic))
        }

        return LibraryImport(resolved: resolved, discarded: discarded)
    }

    /// Matches equivalent releases on OS 26.4+; older systems match more strictly.
    private func findEquivalentsIfAvailable<T>(_ request: inout MusicCatalogResourceRequest<T>) {
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, visionOS 26.4, *) {
            request.options = [.findEquivalents]
        }
    }

    // MARK: - Mapping

    private func artworkURL(_ artwork: Artwork?) -> URL? {
        artwork?.url(width: artworkSize, height: artworkSize)
    }

    private func libraryItem(from song: Song) -> LibraryItem {
        LibraryItem(
            id: song.id.rawValue,
            kind: .song,
            title: song.title,
            subtitle: song.artistName,
            artworkURL: artworkURL(song.artwork),
            isrc: song.isrc
        )
    }

    private func libraryItem(from album: Album) -> LibraryItem {
        LibraryItem(
            id: album.id.rawValue,
            kind: .album,
            title: album.title,
            subtitle: album.artistName,
            artworkURL: artworkURL(album.artwork),
            upc: album.upc
        )
    }

    private func rating(from musicKit: MusicKit.ContentRating?) -> SandboxContentRating? {
        switch musicKit {
        case .clean: .clean
        case .explicit: .explicit
        case .none: nil
        @unknown default: nil
        }
    }

    /// Ancestry arrives attached; the match request already asked for it.
    private func catalogItem(from song: Song) -> CatalogItem {
        var ancestors: [Ancestor] = []
        if let album = song.albums?.first {
            ancestors.append(
                Ancestor(
                    id: CatalogID(.album, album.id.rawValue),
                    rating: rating(from: album.contentRating)
                )
            )
        }
        if let artist = song.artists?.first {
            ancestors.append(Ancestor(id: CatalogID(.artist, artist.id.rawValue)))
        }
        return CatalogItem(
            id: CatalogID(.song, song.id.rawValue),
            title: song.title,
            subtitle: song.artistName,
            artworkURL: artworkURL(song.artwork),
            rating: rating(from: song.contentRating),
            ancestors: ancestors,
            duration: song.duration,
            trackNumber: song.trackNumber
        )
    }

    private func catalogItem(from album: Album) -> CatalogItem {
        var ancestors: [Ancestor] = []
        if let artist = album.artists?.first {
            ancestors.append(Ancestor(id: CatalogID(.artist, artist.id.rawValue)))
        }
        return CatalogItem(
            id: CatalogID(.album, album.id.rawValue),
            title: album.title,
            subtitle: album.artistName,
            artworkURL: artworkURL(album.artwork),
            rating: rating(from: album.contentRating),
            ancestors: ancestors,
            isSingle: album.isSingle,
            trackCount: album.trackCount
        )
    }
}

#endif
