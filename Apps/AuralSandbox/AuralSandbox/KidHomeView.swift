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
    @State private var searchResults: [CatalogItem]?
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
    private var shown: [CatalogItem] { searchResults ?? (recents + mine) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let searchResults {
                    if isLoading && searchResults.isEmpty {
                        ProgressView()
                    } else if searchResults.isEmpty {
                        ContentUnavailableView {
                            Label("Nothing to play", systemImage: "magnifyingglass")
                        }
                    } else {
                        TileGrid(items: searchResults) { item in
                            Task { await playSong(item) }
                        }
                    }
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
            if new.isEmpty { searchResults = nil }
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
                searchResults = try await session.search(term: term).items
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork loads after the item, by URL. Its bytes are never copied
            // into our storage — the MusicKit terms do not allow it.
            AsyncImage(url: item.artworkURL) { image in
                image.resizable().aspectRatio(1, contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary).aspectRatio(1, contentMode: .fit)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
