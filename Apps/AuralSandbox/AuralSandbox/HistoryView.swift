import CatalogKit
import FamilyStore
import SwiftUI

/// Everywhere this kid has been, most recent first, a page at a time.
///
/// A flat list rather than the shelf's tiles: the shelf is a handful of things
/// picked between by sight, this is the long form, and reading a long list is
/// reading titles.
///
/// **The Recent shelf with the grouping taken off.** The shelf collapses a run
/// through one record into the record, hides an artist whose work is already on
/// it, and hides a track whose record is. All of that is a reading of this list,
/// and this is the list. They used to come from different tables — the shelf
/// from arrivals and this from plays — which meant the screen behind a "more of
/// this" chevron showed something else, and a header that lies is worse than a
/// screen that is merely long.
///
/// **What they reached and may still reach.** Anything denied since is absent,
/// for the same reason it vanishes from the shelf: a tile a kid can see and
/// cannot play is an invitation to ask why. So this is honestly not a complete
/// record, and the complete record is the parent's report — which keeps the
/// blocks too, with their reasons.
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
                    Label("Nothing here yet", systemImage: "clock")
                }
            } else {
                // A flat list, not the shelf's tiles. The shelf is a few things
                // picked between by sight; this is the long form, and reading a
                // long list is reading titles — the same trade ``SongList``
                // already makes. What changed is only that the rows now have to
                // draw records and artists as well as songs.
                ScrollView {
                    RecentRows(session: session, items: items) { item in
                        Task { await play(item) }
                    }

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

        // A loop rather than one pass, because a page can arrive with nothing
        // new on it: repeats are collapsed, and a kid who spent an evening on
        // one record produced a page of arrivals that are all the same two
        // things. Stopping there would leave the spinner sitting under an
        // unchanged list with everything older still behind it.
        while hasMore {
            do {
                let result = try await session.recentEvents(page: page)
                page += 1
                hasMore = result.hasMore

                // Within a page the source has already done this. Across pages
                // it has to happen here: boundaries cut through runs, so what a
                // kid was on at the end of one page is often the top of the
                // next.
                let known = Set(items.map(\.id))
                let fresh = result.items.filter { !known.contains($0.id) }
                items += fresh
                if !fresh.isEmpty { return }
            } catch {
                hasMore = false
                return
            }
        }
    }

    /// Only songs play from here; a record or an artist opens, which the row
    /// decides for itself.
    private func play(_ item: CatalogItem) async {
        await player.play(item, from: items.filter { $0.id.kind == .song }, origin: .home)
    }
}
