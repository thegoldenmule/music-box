import CatalogKit
import FamilyStore
import SwiftUI

/// The kid's app. Big tiles, one job, no way out.
///
/// What is deliberately absent matters as much as what is here. No links out,
/// nothing about subscriptions or buying anything, no "more like this", no
/// blocked items shown as tappable-then-refusing, and **no search field at all
/// in level 1** — not present and empty, absent, because an empty search box is
/// an invitation to keep trying.
struct KidHomeView: View {
    @Bindable var session: Session
    @State private var player: KidPlayerModel

    @State private var recents: [CatalogItem] = []
    @State private var mine: [CatalogItem] = []
    @State private var term = ""
    @State private var searchResults: KindedResults?
    @State private var filter: SearchFilter = .all
    @State private var isLoading = false
    @State private var trouble: String?
    @State private var showingAdmin = false
    /// Type-erased, because this stack pushes two unrelated things: a
    /// `CatalogItem` when browsing into a container, and a ``HomeRoute`` for the
    /// history. A `[CatalogItem]` path accepts only the former and refuses the
    /// latter at runtime — it compiles, and the link simply does not work.
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    init(session: Session) {
        self.session = session
        _player = State(initialValue: KidPlayerModel(session: session))
    }

    private var canSearch: Bool { session.kid.mode != .allowOnly }

    /// Everything currently tappable, which is what a play queues from.
    ///
    /// The *visible* results, not every result: a kid looking at Songs should
    /// get a queue of the songs they can see, not one silently padded out of a
    /// tab they are not on.
    private var shown: [CatalogItem] { visible ?? (recents + mine) }

    /// What the results grid is showing, once the filter has had its say.
    private var visible: [CatalogItem]? {
        guard let searchResults else { return nil }
        guard let kind = filter.kind else { return searchResults.items }
        return searchResults.items(of: kind)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let searchResults {
                    results(searchResults)
                } else {
                    home
                }
            }
            .navigationTitle(session.kid.name)
            .navigationDestination(for: CatalogItem.self) { container in
                BrowseView(session: session, player: player, container: container)
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .history:
                    HistoryView(session: session, player: player)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // The one route off this screen, and it is a locked door
                    // rather than a link: it opens the gate, not the admin.
                    Button {
                        showingAdmin = true
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { NowPlayingBar(session: session, player: player) }
        }
        .modifier(
            SearchIfAllowed(enabled: canSearch, term: $term, onSubmit: runSearch)
        )
        .sheet(isPresented: $showingAdmin, onDismiss: reload) {
            NavigationStack {
                if session.isAdminOpen {
                    AdminView(session: session) {
                        session.closeAdmin()
                        showingAdmin = false
                    }
                } else {
                    AdminGateView(session: session) {}
                }
            }
        }
        .task { reload() }
        .onChange(of: term) { _, new in
            if new.isEmpty {
                searchResults = nil
                filter = .all
            }
        }
        // A play is written when the track ends, is skipped, or the app goes
        // away — duration is the signal, and there is no stop control. So
        // recents changes when what is playing changes, which is when to look
        // again.
        .onChange(of: player.current?.id) { _, _ in
            if searchResults == nil { reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Otherwise a kid who plays one song and puts the phone down never
            // produces a play event at all.
            if phase != .active {
                player.flush()
            } else if searchResults == nil {
                reload()
            }
        }
    }

    /// Search results: one list, with a filter across the top.
    ///
    /// One list rather than a section per kind, because sections make the answer
    /// depend on how far a kid scrolls — songs below two rows of albums are
    /// off-screen on a phone. The filter is the whole control surface, and it
    /// costs nothing to use: every kind was fetched by the one search, so
    /// switching is a redraw rather than a round trip.
    @ViewBuilder
    private func results(_ results: KindedResults) -> some View {
        let items = visible ?? []

        VStack(spacing: 0) {
            // Only kinds that found something. Four tabs where three lead to an
            // empty screen is three dead ends a kid has no way to interpret —
            // and for a narrow term that is the common case, not the edge one.
            let filters = SearchFilter.available(for: results)
            if filters.count > 2 {
                Picker("Show", selection: $filter) {
                    ForEach(filters) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if isLoading && items.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if items.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label("Nothing to play", systemImage: "magnifyingglass")
                }
                Spacer()
            } else {
                TileGrid(items: items) { item in
                    Task { await playSong(item) }
                }
            }
        }
    }

    /// Recents first at every level, then whatever else this level offers.
    ///
    /// Recents on top even in level 1, where home used to be the allow list
    /// alone. It is safe there precisely because it is filtered at render time:
    /// a level 1 recent is something that was on the allow list when it played
    /// and still is now, so this is a shortcut into the allow list rather than a
    /// way around it.
    @ViewBuilder
    private var home: some View {
        if isLoading && recents.isEmpty && mine.isEmpty {
            ProgressView()
        } else if recents.isEmpty && mine.isEmpty {
            ContentUnavailableView {
                Label(
                    session.kid.mode == .allowOnly
                        ? "Nothing here yet"
                        : "Pick something to listen to",
                    systemImage: "music.note.list"
                )
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !recents.isEmpty {
                        Section {
                            RecentRow(items: recents) { item in
                                Task { await playSong(item) }
                            }
                        } header: {
                            NavigationLink(value: HomeRoute.history) {
                                HStack {
                                    Text("Recent").font(.title2.bold())
                                    Image(systemName: "chevron.right")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !mine.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Yours").font(.title2.bold()).padding(.horizontal)
                            TileWrap(items: mine) { item in
                                Task { await playSong(item) }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }

    // MARK: - Loading

    private func reload() {
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                recents = try await session.homeItems()
                mine = session.kid.mode == .allowOnly
                    ? try await session.allowListItems()
                    : []
            } catch {
                trouble = Session.message(for: error)
            }
        }
    }

    private func runSearch() {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSearch, !term.isEmpty else { return }

        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                // Filtered, and the blocked half still reaches the parent's
                // report even though the kid never sees it.
                //
                // Back to All on every new search. A filter left on Albums from
                // the last term would meet a new one that has none, leaving a
                // segmented control with nothing selected above an empty grid.
                filter = .all
                searchResults = try await session.search(term: term)
            } catch {
                trouble = Session.message(for: error)
            }
        }
    }

    /// Songs play. Containers navigate, which ``TileGrid`` handles itself.
    private func playSong(_ item: CatalogItem) async {
        let origin: PlaybackOrigin = searchResults == nil ? .home : .search(term: term)
        await player.play(item, from: shown.filter { $0.id.kind == .song }, origin: origin)
    }
}

/// `searchable` applied only when the kid's level has search at all.
///
/// A modifier rather than an `if` around the view: toggling `searchable` in a
/// branch rebuilds the navigation stack underneath it.
private struct SearchIfAllowed: ViewModifier {
    let enabled: Bool
    @Binding var term: String
    let onSubmit: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $term, prompt: "What do you want to hear?")
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}

/// Which kind of result the search screen is showing.
///
/// A filter over results already in hand, **not a new search**. Every kind comes
/// back in one round trip, so switching costs nothing and the parent's report
/// records one search rather than one per tap.
///
/// This is a separate type from `ItemKind` rather than an optional one because
/// `all` is a real choice here and not the absence of a choice — and because
/// `ItemKind` has a `playlist` case that the kid's search deliberately does not
/// ask for.
enum SearchFilter: Hashable, Identifiable, CaseIterable {
    case all
    case songs
    case artists
    case albums

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .artists: "Artists"
        case .albums: "Albums"
        }
    }

    /// `nil` for ``all`` — everything, in `KindedResults.displayOrder`.
    var kind: ItemKind? {
        switch self {
        case .all: nil
        case .songs: .song
        case .artists: .artist
        case .albums: .album
        }
    }

    /// The filters worth offering for one set of results.
    ///
    /// Built from what came back, not from what was asked for. A kind that
    /// matched nothing is left out rather than offered as a tab onto an empty
    /// screen.
    static func available(for results: KindedResults) -> [SearchFilter] {
        allCases.filter { filter in
            guard let kind = filter.kind else { return true }
            return results.populatedKinds.contains(kind)
        }
    }
}

/// Where the home screen can go. A `CatalogItem` push is browsing; this is not.
enum HomeRoute: Hashable {
    case history
}

/// Recents, sideways. One row, scrolled horizontally, so it never pushes the
/// rest of the home screen off the bottom no matter how much a kid listens to.
struct RecentRow: View {
    let items: [CatalogItem]
    let onPlay: (CatalogItem) -> Void

    /// A grid column has a width and hands it to the tile. An `HStack` does
    /// not: the tile sizes to its content, so a long song title stretches the
    /// tile instead of wrapping inside it, and one tile fills the screen.
    private let tileWidth: CGFloat = 150

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    Group {
                        if item.id.kind == .song {
                            Button { onPlay(item) } label: { Tile(item: item) }
                        } else {
                            NavigationLink(value: item) { Tile(item: item) }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: tileWidth)
                }
            }
            .padding(.horizontal)
        }
        // Tall enough for artwork at this width plus two lines of title and one
        // of subtitle, so a long name does not crop the artwork above it.
        .frame(height: tileWidth + 76)
    }
}

/// A wrapping grid that does not scroll — for use inside a page that already
/// does. Nesting two scroll views breaks the outer one's gestures.
struct TileWrap: View {
    let items: [CatalogItem]
    let onPlay: (CatalogItem) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
            ForEach(items, id: \.id) { item in
                if item.id.kind == .song {
                    Button { onPlay(item) } label: { Tile(item: item) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: item) { Tile(item: item) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
    }
}

/// Big, square, tappable. Sized for a finger that is not very accurate yet.
struct TileGrid: View {
    let items: [CatalogItem]
    let onPlay: (CatalogItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    // A song is a play; a container is a push. Deciding that
                    // here rather than in a tap handler means the navigation
                    // destination is the enclosing stack's, so browsing nests
                    // without every screen owning a path.
                    if item.id.kind == .song {
                        Button { onPlay(item) } label: { Tile(item: item) }
                            .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: item) { Tile(item: item) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }
}

struct Tile: View {
    let item: CatalogItem

    /// Songs play where they stand; everything else opens. That is the only
    /// distinction a kid needs from a tile, and it is the one the tile draws.
    ///
    /// Deliberately the *action*, not the taxonomy. `TileGrid` already branches
    /// on exactly this to decide between a `Button` and a `NavigationLink`, so
    /// the look and the behaviour cannot drift apart.
    private var opens: Bool { item.id.kind != .song }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
            titleRow
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Padded whatever the kind, so every tile is the same size and a grid
        // of mixed kinds still lines up. Only the fill behind it differs.
        .padding(8)
        .background {
            if opens {
                RoundedRectangle(cornerRadius: 16).fill(.quaternary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        // Shape and glyph are invisible to VoiceOver, which otherwise announces
        // an album and a song of the same name identically.
        .accessibilityHint(Text(opens ? "Opens" : "Plays"))
    }

    /// **Never cropped, covered, or composited onto.**
    ///
    /// The Developer Program License Agreement §3.3.6(D) says MusicKit Content
    /// may not be *modified*, and does not define the word. Masking artwork to a
    /// circle removes part of it and a play badge laid over it obscures part of
    /// it — so the kind is drawn everywhere except here. The corner radius is
    /// the one liberty taken, and it is a considered one rather than an
    /// inherited default: near-universal in MusicKit apps, and the shape of the
    /// frame rather than a change to what the frame contains.
    ///
    /// Bytes are referenced by URL and never copied into our storage, which the
    /// same clause forbids outright.
    private var artwork: some View {
        AsyncImage(url: item.artworkURL) { image in
            image.resizable().aspectRatio(1, contentMode: .fit)
        } placeholder: {
            // A steady sight, not a flicker on the way to artwork: plenty of
            // artists have no image in the catalog at all, so this is what their
            // tile looks like for good. A glyph reads as "a person" where a bare
            // grey slab reads as something still loading.
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: placeholderGlyph)
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: glyph)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.headline)
                // Two lines whether or not the title needs them. Without it a
                // one-line title makes a shorter tile than a two-line one and
                // every grid row sits on a ragged baseline — invisible while
                // tiles were bare, obvious the moment containers grew a card.
                .lineLimit(2, reservesSpace: true)
            Spacer(minLength: 0)
        }
    }

    /// The kind's own mark, on its own silhouette.
    ///
    /// This was a chevron for containers and a play triangle for songs, which
    /// is two rightward wedges at caption size — no distinction at all once
    /// they are 8 points tall and next to each other in a grid.
    ///
    /// Splitting it by kind rather than by action also buys back something the
    /// single chevron lost: an artist and an album are both "opens", so a shared
    /// glyph left them telling apart only by their titles. The card behind the
    /// tile still carries the action; the glyph carries the kind. Two facts, two
    /// channels.
    private var glyph: String {
        switch item.id.kind {
        case .song: "play.fill"
        case .album: "square.stack.fill"
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        }
    }

    private var placeholderGlyph: String {
        switch item.id.kind {
        case .artist: "music.mic"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        // Not `play.fill` here: a play triangle filling the space where artwork
        // should be reads as a button, and this is the one tile you cannot tap
        // to hear anything yet.
        case .song: "music.note"
        }
    }

    /// Always present, so every tile is the same height.
    ///
    /// An artist's `subtitle` is `nil` by design — it would only repeat the
    /// title — which left artist tiles one line shorter than their neighbours
    /// and the grid ragged the moment search started returning them.
    private var subtitle: String {
        item.subtitle ?? item.id.kind.rawValue.capitalized
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.id.kind.rawValue]
        if let subtitle = item.subtitle { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }
}
