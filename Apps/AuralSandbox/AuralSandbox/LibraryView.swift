import CatalogKit
import FamilyStore
import KidLibrary
import SwiftUI

/// Everything the kid has kept, and a way to find one of it.
///
/// Reached from the "Library" shelf rather than from the main search field, and
/// searched by a **local predicate over rows already in hand** — never
/// `MusicLibrarySearchRequest`, which searches the whole signed-in library
/// rather than the kid's own records.
///
/// A kid with forty favorites does not need the search. A kid with four hundred
/// does, and that kid exists a year in.
struct LibraryView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel

    @State private var items: [CatalogItem] = []
    @State private var term = ""
    @State private var isLoading = true
    @State private var isNaming = false
    @State private var trouble: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label(
                        term.isEmpty ? "Nothing kept yet" : "Nothing to play",
                        systemImage: term.isEmpty ? "heart" : "magnifyingglass"
                    )
                } description: {
                    if term.isEmpty {
                        Text("Tap a heart to keep something.")
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !session.playlists.isEmpty, term.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Playlists").font(.title2.bold()).padding(.horizontal)
                                PlaylistShelf(playlists: session.playlists)
                            }
                        }
                        TileWrap(session: session, items: items, origin: .home) { item in
                            Task { await play(item) }
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $term, prompt: "Find something you kept")
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
        // Typed a character at a time. The predicate is local and the rows are
        // already resolved, so there is nothing to debounce and no request to
        // cancel — the difference from the catalog search field is the whole
        // reason this one lives here.
        .onChange(of: term) { _, _ in Task { await load() } }
        .onChange(of: session.favoriteIDs) { _, _ in Task { await load() } }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            items = term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try await session.favoriteItems()
                : try await session.searchLibrary(term)
        } catch {
            trouble = Session.message(for: error)
        }
    }

    private func play(_ item: CatalogItem) async {
        await player.play(item, from: items.filter { $0.id.kind == .song }, origin: .home)
    }
}
