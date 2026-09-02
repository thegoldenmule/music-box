import CatalogKit
import FamilyStore
import KidLibrary
import SwiftUI

/// Everything the kid has kept, by kind, with a way to narrow each.
///
/// **Four columns and a drill-in, the way a file browser works.** The screen this
/// replaced was one grid of everything in the order it was hearted, which is fine
/// at forty rows and unusable at four hundred — and four hundred is where a kid
/// is a year in. Artists, albums and songs are alphabetical; the filter field
/// narrows as they type; tapping an artist opens their albums and tapping an
/// album opens its songs.
///
/// **Closed over the library.** An artist's albums here are the albums the kid
/// has kept, not everything that artist released — `ArtistView` is the screen
/// that opens the catalog, and this one deliberately is not a second way in.
///
/// Nothing on this screen fetches. ``Session/libraryContents`` is read once and
/// every column, every drill-in and every keystroke is a filter of it, which is
/// what keeps a spinner out from between a tap and what it opened.
///
/// The engine has already been through it. A row here is one the kid may play
/// today — not one they were allowed to keep, which is a different and older
/// question — and the player asks a third time before any of it makes a sound.
struct LibraryView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel

    /// Artists, which is the top of the tree and the shortest list of the four.
    ///
    /// It is also the column least changed by how the library was filled. Songs
    /// and Albums show only what the kid picked out, so a library built by
    /// keeping one artist opens on an empty column and an explanation; Artists
    /// has the artist in it either way.
    @State private var filter = LibraryFilter.artists
    @State private var term = ""
    @State private var isNaming = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            content
        }
        .navigationTitle("Library")
        .searchable(text: $term, prompt: filter.prompt)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isNaming = true
                } label: {
                    Label("New playlist", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isNaming) { NamePlaylistSheet(session: session) }
        .task { await load() }
        // A heart filled or emptied anywhere in the app changes what belongs in
        // these columns — unhearting the last song on a record takes the record
        // out of the Albums column with it.
        .onChange(of: session.favoriteIDs) { _, _ in Task { await load() } }
        // And the Apple library arriving, which fills no heart and changes
        // every column.
        .onChange(of: session.appleLibraryGeneration) { _, _ in Task { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        if !session.hasLoadedLibrary {
            Spacer()
            ProgressView()
            Spacer()
        } else if rows.isEmpty && playlists.isEmpty {
            Spacer()
            LibraryEmpty(
                filter: filter,
                isSearching: !term.isEmpty,
                // The *whole* library, not this column's slice of it — which is
                // the distinction the third sentence exists to draw.
                hasLibrary: !session.libraryContents.albums.isEmpty
                    || !session.libraryContents.artists.isEmpty
                    || !session.libraryContents.songs.isEmpty
            )
            Spacer()
        } else if filter == .playlists {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(playlists.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, SongRowMetrics.textInset)
                        }
                        LibraryPlaylistRow(row: row)
                    }
                }
            }
        } else if filter == .songs {
            SongList(session: session, items: rows, origin: .home) { item in
                Task { await player.play(item, from: rows, origin: .home) }
            }
        } else {
            LibraryContainerList(session: session, items: rows)
        }
    }

    /// The column, filtered. Recomputed per draw and cheap enough to be: these
    /// are arrays already in memory and the predicate is a substring match.
    private var rows: [CatalogItem] {
        let contents = session.libraryContents
        return switch filter {
        case .artists: LibraryBrowse.filter(contents.artists, by: term)
        // Only what the kid picked, the same way Songs is — see `chosenAlbums`.
        // A record that came in behind an artist is one level in, under them.
        case .albums: LibraryBrowse.filter(contents.chosenAlbums, by: term)
        // **Only what the kid picked.** Keeping an artist can bring a thousand
        // tracks in, and a Songs column holding all of them buries the dozen a
        // child actually chose. The rest is not hidden — it is one level in,
        // under the artist or the record it arrived with, which is where someone
        // looking for it would go.
        //
        // Sorted here and not upstream: `LibraryContents.songs` is in fold order,
        // which is what decides where a container's artwork comes from, and a
        // column is read by name.
        case .songs: LibraryBrowse.filter(LibraryBrowse.sorted(contents.chosenSongItems), by: term)
        case .playlists: []
        }
    }

    /// Playlists are not catalog items and are never judged — the engine has no
    /// opinion on a list a child made. Their *songs* are judged when opened.
    private var playlists: [PlaylistRow] {
        guard filter == .playlists else { return [] }
        let sorted = session.playlists.sorted {
            LibraryBrowse.sortKey($0.name) < LibraryBrowse.sortKey($1.name)
        }
        guard !term.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func load() async {
        await session.loadLibrary()
    }
}

/// One artist's albums, as they exist in the library.
///
/// Songs by the artist that name no album follow underneath rather than being
/// unreachable. That case should be rare — ancestry arrives as album-and-artist
/// together — but "rare" is not "never", and a kid who taps an artist and is
/// told there is nothing there while the Songs column plainly lists their work
/// has found a bug, whatever the schema says.
struct LibraryArtistView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel
    let artist: CatalogID

    @State private var term = ""

    private var origin: PlaybackOrigin { .browse(artist) }

    var body: some View {
        Group {
            if albums.isEmpty && loose.isEmpty {
                LibraryEmpty(filter: .albums, isSearching: !term.isEmpty)
            } else {
                ScrollView {
                    LibraryContainerRows(session: session, items: albums)
                    if !loose.isEmpty {
                        SongRows(session: session, items: loose, origin: origin) { item in
                            Task { await player.play(item, from: loose, origin: origin) }
                        }
                    }
                }
            }
        }
        .navigationTitle(name)
        .searchable(text: $term, prompt: "Find a record")
    }

    private var name: String {
        session.libraryContents.artists.first { $0.id == artist }?.title ?? "Artist"
    }

    private var songs: [LibrarySong] { session.libraryContents.songs }

    /// **The whole library's albums, not the Albums column's.** This is the
    /// screen the column's exclusions point at: everything a walk brought in
    /// under this artist lives here, which is the only reason it is safe to keep
    /// it off the top level.
    ///
    /// Taken from the album list rather than folded out of songs so that a record
    /// whose tracks failed to load is still here. A fold would have no song to
    /// build it from and would silently drop it.
    private var everyAlbum: [CatalogItem] {
        LibraryBrowse.albums(session.libraryContents.albums, by: artist)
    }

    private var albums: [CatalogItem] {
        LibraryBrowse.filter(everyAlbum, by: term)
    }

    /// This artist's songs that no album in `albums` accounts for.
    private var loose: [CatalogItem] {
        let covered = Set(everyAlbum.map(\.id))
        let orphans = songs
            .filter { $0.ancestry.artist == artist }
            .filter { $0.ancestry.album.map { !covered.contains($0) } ?? true }
            .map(\.item)
        return LibraryBrowse.filter(LibraryBrowse.sorted(orphans), by: term)
    }
}

/// One album's songs, in track order.
struct LibraryAlbumView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel
    let album: CatalogID

    @State private var term = ""

    private var origin: PlaybackOrigin { .browse(album) }

    var body: some View {
        Group {
            if songs.isEmpty {
                // Reachable: a kid can heart a record without keeping any track
                // off it, and the drill-in is closed over the library.
                LibraryEmpty(filter: .songs, isSearching: !term.isEmpty)
            } else {
                SongList(session: session, items: songs, origin: origin) { item in
                    Task { await player.play(item, from: songs, origin: origin) }
                }
            }
        }
        .navigationTitle(name)
        .searchable(text: $term, prompt: "Find a song")
    }

    private var name: String {
        session.libraryContents.albums.first { $0.id == album }?.title ?? "Album"
    }

    private var songs: [CatalogItem] {
        LibraryBrowse.filter(
            LibraryBrowse.songs(from: session.libraryContents.songs, on: album),
            by: term
        )
    }
}

// MARK: - Pieces

/// Which column is showing.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case artists
    case albums
    case songs
    case playlists

    var id: Self { self }

    var label: String {
        switch self {
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .playlists: "Playlists"
        }
    }

    /// Named for what the kid is looking for rather than for the field, because
    /// the field is the same one on four screens and the thing being searched is
    /// the only part that changes.
    var prompt: String {
        switch self {
        case .artists: "Find an artist"
        case .albums: "Find a record"
        case .songs: "Find a song"
        case .playlists: "Find a playlist"
        }
    }
}

/// A scrolling column of records or artists.
struct LibraryContainerList: View {
    @Bindable var session: Session
    let items: [CatalogItem]

    var body: some View {
        ScrollView {
            LibraryContainerRows(session: session, items: items)
        }
    }
}

/// The rows on their own, for a page that already scrolls — the same split
/// ``SongRows`` makes out of ``SongList``, for the same reason.
///
/// Every row points at the library's own route rather than at the catalog page
/// for the thing, which is what keeps the drill-in closed over the library.
struct LibraryContainerRows: View {
    @Bindable var session: Session
    let items: [CatalogItem]

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, SongRowMetrics.textInset)
                }
                ContainerRow(session: session, item: item, route: route(for: item))
            }
        }
    }

    private func route(for item: CatalogItem) -> KidRoute {
        switch item.id.kind {
        case .artist: .home(.libraryArtist(item.id))
        case .album: .home(.libraryAlbum(item.id))
        // Neither can be in one of these columns. Falling back to the catalog
        // page is what this row does everywhere else, so it is the answer that
        // surprises nobody if it ever happens.
        default: .container(item)
        }
    }
}

/// One playlist as a row, shaped like ``ContainerRow`` beside it.
///
/// Its own type rather than a `ContainerRow` because a playlist has no
/// `CatalogItem` to be — a list a child made has no catalog identifier, which is
/// the whole reason ``PlaylistHandle`` exists.
struct LibraryPlaylistRow: View {
    let row: PlaylistRow

    var body: some View {
        NavigationLink(value: KidRoute.home(.playlist(row.handle))) {
            HStack(spacing: SongRowMetrics.gap) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Image(systemName: "music.note.list").foregroundStyle(.secondary)
                }
                .frame(width: SongRowMetrics.artworkSize, height: SongRowMetrics.artworkSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(row.entries.count == 1 ? "1 song" : "\(row.entries.count) songs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: SongRowMetrics.gap)

                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: HeartButton.size, height: HeartButton.size)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, SongRowMetrics.margin)
            .padding(.vertical, 10)
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens"))
    }
}

/// What an empty column says.
///
/// Three different sentences, because they are three different problems. A kid
/// whose filter matched nothing should try another word. A kid who has kept
/// nothing should be told how to keep something. And a kid whose Songs or Albums
/// column is empty **while their library plainly is not** — which is exactly what
/// keeping an artist and nothing else looks like — must not be told to tap a
/// heart they just tapped; they should be pointed one level in, where everything
/// that artist brought with them is.
struct LibraryEmpty: View {
    let filter: LibraryFilter
    let isSearching: Bool

    /// Whether anything at all is kept, whatever this column shows.
    var hasLibrary = false

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: glyph)
        } description: {
            Text(detail)
        }
    }

    /// This column is empty and the library is not — the state only the two
    /// filtered columns can be in.
    private var isFullElsewhere: Bool {
        hasLibrary && !isSearching && (filter == .songs || filter == .albums)
    }

    private var title: String {
        if isSearching { return "Nothing found" }
        guard isFullElsewhere else { return "Nothing kept yet" }
        return filter == .songs ? "No songs kept on their own" : "No records kept on their own"
    }

    private var glyph: String {
        if isSearching { return "magnifyingglass" }
        if isFullElsewhere { return "music.note.list" }
        return "heart"
    }

    private var detail: String {
        if isSearching { return "Try a different word." }
        if isFullElsewhere {
            return filter == .songs
                ? "Open an artist or a record to find their songs."
                : "Open an artist to find their records."
        }
        if filter == .playlists { return "Make a playlist with the + button." }
        return "Tap a heart to keep something."
    }
}
