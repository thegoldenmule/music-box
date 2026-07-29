#if canImport(MusicKit)

import Foundation
import MusicKit
import PolicyEngine

/// The one place in the app that imports MusicKit.
///
/// Everything here is mapping: MusicKit types in, ``CatalogItem`` out. Keeping
/// it mechanical is the point — the interesting behaviour lives in
/// ``FilteredCatalog``, which is testable without a subscription, a network, or
/// a device.
public struct MusicKitCatalogSource: CatalogSource {
    /// Pixel size requested for artwork URLs. Artwork is referenced by URL and
    /// cached like any image; the MusicKit terms do not let us copy it into our
    /// own storage.
    private let artworkSize: Int

    /// Apple Music's hard cap on `limit` for a search request.
    ///
    /// Verified on device, the expensive way: asking for 75 returns
    /// `400 / 40005 Invalid Parameter Value — Value must be an integer less
    /// than or equal to 25`, and every search failed. Other endpoints allow
    /// more; search does not.
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

        // Clamped rather than passed through: a caller asking for more than the
        // API allows should get a short page, not a failed search. The clamped
        // value is what `hasMore` is judged against below — comparing against
        // the *asked-for* limit would read a full 25 as "fewer than 75, so the
        // catalog is exhausted" and stop paging on the first request.
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

        // MusicKit gives no total count, so "there may be more" is inferred from
        // getting back a full page. Overshooting by one empty request at the end
        // is cheaper than stopping early and claiming a search found nothing.
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

    /// One request per kind, rather than one per item.
    ///
    /// Grouped by kind because `MusicCatalogResourceRequest` is typed: songs,
    /// albums, artists and playlists cannot travel in one request. Four
    /// requests for a screen of thirty tiles instead of thirty.
    ///
    /// Missing items are dropped rather than reported. An identifier that no
    /// longer resolves is a delisting, and every caller of this is rendering a
    /// list where the right answer is simply not to show it.
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

    private func items(ofKind kind: ItemKind, ids: [MusicItemID]) async throws -> [CatalogItem] {
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

    /// Asked for as a property of the lookup rather than by fetching the artist
    /// and asking again with `with(_:)` — one request instead of two, which is
    /// what the rest of ``children(of:)`` still costs and should probably learn.
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

    /// Everyone credited, not just the first one.
    ///
    /// The asymmetry with ``ancestry(of:)-(Album)`` is deliberate: that keeps one
    /// artist because one container is all a deny needs, and this returns the
    /// whole credit because a record made by two artists names two.
    ///
    /// Empty identifiers are dropped for the same reason they are dropped from
    /// ancestry — a chip that links nowhere is worse than no chip.
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

        // An artist is their own credit, and a playlist's tracks each carry
        // their own — there is no one answer for the container.
        case .artist, .playlist:
            return []
        }
    }

    // MARK: - Ancestry

    /// Batched, because search results arrive without relationships and the
    /// policy engine cannot judge a song against a denied artist without one.
    ///
    /// Only songs and albums need this — artists have no ancestry, and a
    /// playlist's lineage is supplied by whoever is playing it, not fetched.
    public func resolveAncestry(for items: [CatalogItem]) async throws -> [CatalogItem] {
        // Empty identifiers are filtered out rather than sent. A request built
        // from one asks Apple Music for an item that cannot exist, and the row
        // it would fail to match is better left with no lineage — which the
        // policy engine already treats as provisional.
        let songIDs = items
            .filter { $0.id.kind == .song && $0.ancestors.isEmpty && !$0.id.rawValue.isEmpty }
            .map { MusicItemID($0.id.rawValue) }
        let albumIDs = items
            .filter { $0.id.kind == .album && $0.ancestors.isEmpty && !$0.id.rawValue.isEmpty }
            .map { MusicItemID($0.id.rawValue) }

        var ancestryByID: [CatalogID: [Ancestor]] = [:]

        if !songIDs.isEmpty {
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: songIDs)
            request.properties = [.albums, .artists]
            let response = try await mapErrors { try await request.response() }
            for song in response.items {
                ancestryByID[CatalogID(.song, song.id.rawValue)] = ancestry(of: song)
            }
        }

        if !albumIDs.isEmpty {
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, memberOf: albumIDs)
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

    /// An ancestor with an empty identifier is dropped, not stored.
    ///
    /// MusicKit will hand back a relationship item whose identifier set is
    /// empty — it says so in the log: *"A MusicIdentifierSet with empty string
    /// … is being used"*. Storing that as `CatalogID(.album, "")` is worse than
    /// storing nothing. It matches no real album, so a parent's deny on that
    /// album never fires; every such song shares one identifier, so they are
    /// indistinguishable; and worst of all the item then *looks* like it has
    /// lineage. The provisional-verdict rule — deny fails open, allow-only
    /// fails closed — keys off ancestry being empty, and a bogus entry makes a
    /// guess read as a resolved fact.
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
            // Both come back with the song itself — no extra property, no second
            // request — so they cost nothing to carry and are absent forever if
            // the screen that wants them has to ask separately.
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
            // `isSingle` is optional in MusicKit too, and the optionality is
            // carried rather than flattened here — see
            // ``CatalogItem/isSingleRelease``, which is the one place that
            // decides what an absent flag means.
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
            // Artists carry no rating. The policy engine treats them as
            // containers and judges what is inside them individually.
            rating: nil
        )
    }

    private func item(from playlist: Playlist) -> CatalogItem {
        CatalogItem(
            id: CatalogID(.playlist, playlist.id.rawValue),
            title: playlist.name,
            subtitle: playlist.curatorName,
            artworkURL: artworkURL(playlist.artwork),
            // `Playlist` has no `contentRating` property at all — judged track
            // by track as each one comes up.
            rating: nil
        )
    }

    private func item(from track: Track) -> CatalogItem? {
        switch track {
        case .song(let song):
            return item(from: song)
        case .musicVideo:
            // Music videos are out of scope: no player surface for them, and
            // they would need their own rating handling.
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

/// Reads the account's library so a parent can seed lists from their own music.
///
/// Everything read here is matched to the Apple Music catalog before it goes
/// anywhere. Nothing library-only is ever stored — see ``LibrarySource`` for why
/// that rule exists.
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
    //
    // **Unverified on device, like everything else in this file.** The MusicKit
    // capability is not enabled on the App ID, so what follows compiles against
    // the real SDK and has been run against nothing.

    public func libraryPlaylists(limit: Int) async throws -> [LibraryPlaylist] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = limit
        let response = try await catalog.mapErrors { try await request.response() }
        return response.items.map(libraryPlaylist(from:))
    }

    /// One playlist's tracks.
    ///
    /// Refetched by identifier rather than carried on the value, because
    /// ``LibraryPlaylist`` crosses into the app and a `MusicItemCollection` is
    /// not a thing to hand across that boundary.
    ///
    /// Music videos are dropped rather than discarded with a reason: there is no
    /// player surface for one, so it is out of scope rather than unmatchable —
    /// the same call `children(of:)` makes for a catalog playlist.
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

    /// Names a library artist in the catalog by resolving a sample of their songs.
    ///
    /// The songs are found by searching the library for the artist's name rather
    /// than by filtering on the relationship. A name search can over-match — a
    /// band whose name is a common word will pull in songs that are not theirs —
    /// and that is exactly what the vote is there to absorb: wrong songs have to
    /// outnumber right ones before they can carry the result, and if they come
    /// close nobody wins and the parent is told to use catalog search instead.
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
            // A playlist the account holder made carries no `kind` at all;
            // every case of `Playlist.Kind` names something Apple produced,
            // `personalMix` included — that one is a mix Apple built *for*
            // them, which is not the same as one they built. Unverified on
            // device like the rest of this file, and it decides nothing: both
            // kinds resolve their tracks the same way, and this only picks the
            // label the parent reads.
            isPersonal: playlist.kind == nil
        )
    }

    /// Match library items to the catalog by recording and product code.
    ///
    /// Two batched requests, one for songs and one for albums, regardless of how
    /// many items the parent selected.
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

        // Anything that had a code but came back with no match is not on Apple
        // Music — a delisted record, a regional gap, a bootleg. Discarded, and
        // named, so the parent can see what did not make it.
        for (isrc, item) in songsByISRC where !matchedISRCs.contains(isrc) {
            discarded.append(DiscardedItem(item: item, reason: .notInAppleMusic))
        }
        for (upc, item) in albumsByUPC where !matchedUPCs.contains(upc) {
            discarded.append(DiscardedItem(item: item, reason: .notInAppleMusic))
        }

        return LibraryImport(resolved: resolved, discarded: discarded)
    }

    /// Ask the catalog to consider equivalent releases, on OS versions that
    /// offer it.
    ///
    /// A recording code identifies a specific release, and the copy in someone's
    /// library is often not the copy their storefront carries — a regional
    /// pressing, a reissue, a different master. Without this those come back
    /// unmatched and get discarded, which reads to a parent as "Apple Music does
    /// not have this record" when it plainly does.
    ///
    /// Opportunistic on purpose. It arrived in iOS and macOS 26.4, and the
    /// floor stays at iOS 17 so hand-me-down hardware still runs the app. Older
    /// systems simply match more strictly.
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

    /// Resolved items come back with ancestry already attached, since the match
    /// request asked for the relationships anyway. That means a seeded song is
    /// immediately judgeable against a denied artist.
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
