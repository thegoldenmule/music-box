import CatalogKit
import SwiftUI

/// Inside an artist or an album.
///
/// Everything here has already been through the policy engine. A blocked track
/// is **absent**, not greyed out and not shown with a lock — in levels 1 and 2 a
/// kid never sees something they cannot have, because a thing you can see and
/// cannot touch is an invitation to ask why.
///
/// The blocked half is not discarded, though. It goes to the parent's report
/// with its reason, which is how a parent learns what their kid went looking
/// for.
struct BrowseView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel
    let container: CatalogItem

    @State private var items: [CatalogItem] = []
    @State private var isLoading = true
    @State private var trouble: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to play here", systemImage: "music.note")
                }
            } else {
                TileGrid(items: items) { item in
                    Task { await playSong(item) }
                }
            }
        }
        .navigationTitle(container.title)
        .safeAreaInset(edge: .bottom) { NowPlayingBar(session: session, player: player) }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let results = try await session.children(of: container.id)
            items = results.items
            // Filtered out of a surface the kid asked for, so still logged —
            // even though nothing here was ever rendered.
            session.logBlocked(results.blocked, origin: .browse(container.id))
        } catch {
            trouble = Session.message(for: error)
        }
    }

    private func playSong(_ item: CatalogItem) async {
        await player.play(
            item,
            from: items.filter { $0.id.kind == .song },
            origin: .browse(container.id)
        )
    }
}
