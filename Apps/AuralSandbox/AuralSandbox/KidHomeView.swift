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

    @State private var items: [CatalogItem] = []
    @State private var term = ""
    @State private var searchResults: [CatalogItem]?
    @State private var isLoading = false
    @State private var trouble: String?
    @State private var showingAdmin = false
    @State private var path: [CatalogItem] = []

    init(session: Session) {
        self.session = session
        _player = State(initialValue: KidPlayerModel(session: session))
    }

    private var canSearch: Bool { session.kid.mode != .allowOnly }

    private var shown: [CatalogItem] { searchResults ?? items }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isLoading && shown.isEmpty {
                    // A loading state, never an empty one. "Nothing here" and
                    // "not loaded yet" look identical to a child and mean
                    // opposite things.
                    ProgressView()
                } else if shown.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: "music.note.list")
                    }
                } else {
                    TileGrid(items: shown) { item in
                        Task { await playSong(item) }
                    }
                }
            }
            .navigationTitle(session.kid.name)
            .navigationDestination(for: CatalogItem.self) { container in
                BrowseView(session: session, player: player, container: container)
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
    }

    private var emptyTitle: String {
        if searchResults != nil { return "Nothing to play" }
        return session.kid.mode == .allowOnly
            ? "Nothing here yet"
            : "Pick something to listen to"
    }

    // MARK: - Loading

    private func reload() {
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                items = try await session.homeItems()
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
