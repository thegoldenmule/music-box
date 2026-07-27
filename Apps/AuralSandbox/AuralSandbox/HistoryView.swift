import CatalogKit
import SwiftUI

/// Everything this kid has played, most recent first, a page at a time.
///
/// **A history of what they played and may still play.** Anything denied since
/// is absent, for the same reason it vanishes from recents: a tile a kid can see
/// and cannot play is an invitation to ask why, and every other surface in the
/// app already refuses to show one.
///
/// So this is honestly not a complete record, and the complete record is the
/// parent's report — which keeps the blocks too, with their reasons.
struct HistoryView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel

    @State private var items: [CatalogItem] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false

    var body: some View {
        Group {
            if items.isEmpty && isLoading {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing played yet", systemImage: "clock")
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(items, id: \.id) { item in
                            Button {
                                Task { await play(item) }
                            } label: {
                                Tile(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()

                    if hasMore {
                        // Paged on appearance rather than by a button: a child
                        // should not have to know what a page is.
                        ProgressView()
                            .padding()
                            .task { await loadNextPage() }
                    }
                }
            }
        }
        .navigationTitle("Recent")
        .safeAreaInset(edge: .bottom) { NowPlayingBar(session: session, player: player) }
        .task {
            guard items.isEmpty else { return }
            await loadNextPage()
        }
    }

    private func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await session.playHistory(page: page)
            // De-duplicated across pages as well as within one: over-fetching
            // to survive filtering means page boundaries can overlap.
            let known = Set(items.map(\.id))
            items += result.items.filter { !known.contains($0.id) }
            hasMore = result.hasMore
            page += 1
        } catch {
            hasMore = false
        }
    }

    private func play(_ item: CatalogItem) async {
        await player.play(item, from: items, origin: .home)
    }
}
