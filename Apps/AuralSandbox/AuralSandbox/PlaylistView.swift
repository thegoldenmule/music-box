import CatalogKit
import FamilyStore
import KidLibrary
import SwiftUI

/// One playlist a kid made: its songs, in the order they put them in.
///
/// Order is the content, so the drag is the edit. Everything else — rename,
/// delete, remove a song — is one gesture too.
///
/// Playing it queues the songs in order, and the player re-checks every track
/// immediately before it plays. That is what makes a playlist built weeks ago
/// safe to press play on today: a song denied since is skipped, and the kid is
/// told only that one is being skipped, never why.
struct PlaylistView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel
    let handle: PlaylistHandle

    @State private var songs: [CatalogItem] = []
    @State private var isLoading = true
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false
    @State private var trouble: String?
    @Environment(\.dismiss) private var dismiss

    private var playlist: PlaylistRow? {
        session.playlists.first { $0.handle.local == handle.local }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if songs.isEmpty {
                ContentUnavailableView {
                    Label("Nothing in here yet", systemImage: "music.note.list")
                } description: {
                    Text("Add songs from anywhere you see one.")
                }
            } else {
                // A `List` rather than the app's own `SongList`, because this is
                // the one screen where the rows are draggable and deletable and
                // those come with the list for free. Plain style so it reads as
                // the same app rather than as Settings.
                List {
                    ForEach(songs, id: \.id) { song in
                        SongRow(item: song) {
                            Task { await play(song) }
                        } accessory: {
                            HeartButton(
                                session: session,
                                item: song,
                                origin: .kidPlaylist(handle.local)
                            )
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                    .onMove(perform: move)
                    .onDelete(perform: remove)
                }
                // No edit mode. `onMove` gives long-press-and-drag on its own,
                // which is the gesture a kid already knows from rearranging
                // icons — and turning edit mode on would put handles and minus
                // signs over rows whose buttons have to stay tappable. It is
                // also `editMode`'s other problem: the environment key does not
                // exist on macOS, and this app builds for both.
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Play all") { Task { await playAll() } }
                        .disabled(songs.isEmpty)
                    Button("Rename…") { isRenaming = true }
                    Button("Delete playlist", role: .destructive) { isConfirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isRenaming) {
            NamePlaylistSheet(
                session: session,
                renaming: handle,
                initialName: playlist?.name ?? ""
            )
        }
        // A playlist is the record in the store with the most of a kid's own work
        // in it. One tap should not be able to end it.
        .confirmationDialog(
            "Delete this playlist?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    trouble = await session.deletePlaylist(handle)
                    if trouble == nil { dismiss() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { NowPlayingBar(session: session, player: player) }
        .task { await load() }
        .onChange(of: playlist?.modifiedAt) { _, _ in Task { await load() } }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            songs = try await session.playlistSongs(handle)
        } catch {
            trouble = Session.message(for: error)
        }
    }

    /// The drag, applied to the whole order at once.
    ///
    /// The new sequence rather than a from/to pair, because a removal on another
    /// screen racing this one would otherwise shift everything below it by one.
    private func move(from source: IndexSet, to destination: Int) {
        var reordered = songs
        reordered.move(fromOffsets: source, toOffset: destination)
        songs = reordered
        Task { trouble = await session.reorderPlaylist(handle, to: reordered.map(\.id)) }
    }

    private func remove(_ offsets: IndexSet) {
        let going = offsets.map { songs[$0].id }
        songs.remove(atOffsets: offsets)
        Task {
            for id in going {
                trouble = await session.removeFromPlaylist(handle, song: id)
            }
        }
    }

    private func play(_ song: CatalogItem) async {
        await player.play(song, from: songs, origin: .kidPlaylist(handle.local))
    }

    private func playAll() async {
        guard let first = songs.first else { return }
        await play(first)
    }
}
