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
    /// Why the list could not be read. Distinct from ``trouble`` because only
    /// this one is rendered: "Can't load this" is the wrong sentence for a
    /// removal that failed to save, and the two failures share nothing but a
    /// type.
    @State private var loadTrouble: String?

    /// A write that did not take. Set and, as before, never shown — what a kid
    /// sees when a reorder fails is its own question, and answering it with the
    /// load state's copy would answer it wrongly.
    @State private var trouble: String?
    @Environment(\.dismiss) private var dismiss

    private var playlist: PlaylistRow? {
        session.playlists.first { $0.handle.local == handle.local }
    }

    var body: some View {
        Group {
            // `songs.isEmpty` as well, so that a reload — a reorder, a removal,
            // any change to `modifiedAt` — does not replace a list the kid is
            // looking at with a spinner.
            if isLoading && songs.isEmpty {
                ProgressView()
            } else if songs.isEmpty, let loadTrouble {
                // Before the empty state and behind `songs.isEmpty`, which is two
                // rules rather than one. Before, because an outage that reaches
                // this screen has already turned every song down, and "nothing
                // here" is the wrong answer to "we could not read your playlist."
                // Behind, because a failed *re*-load still has the last good list
                // in hand, and covering songs a kid can still play with an error
                // is the same mistake in the other direction.
                ContentUnavailableView(
                    "Can't load this",
                    systemImage: "wifi.slash",
                    description: Text(loadTrouble)
                )
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
        .task { await load() }
        .onChange(of: playlist?.modifiedAt) { _, _ in Task { await load() } }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let results = try await session.playlistSongs(handle)
            songs = results.items
            loadTrouble = Self.loadTrouble(with: results)
        } catch {
            loadTrouble = Session.kidMessage(for: error)
        }
    }

    /// Whether a read that did not throw still failed.
    ///
    /// `songs(in:)` swallows a catalog that will not answer and judges the rows
    /// on their bare identifiers instead, which is what keeps the rest of the app
    /// drawing offline. For a playlist it has a second effect: a row judged
    /// without a rating is unrated, and `UnratedBehavior` defaults to `.block`,
    /// so the whole list comes back turned down and `items` is empty. Read from
    /// `items` alone that is indistinguishable from a playlist the kid never put
    /// anything in — and telling a child they have nothing in here is the app
    /// describing its own outage as their empty playlist.
    ///
    /// **Only when nothing survived.** An unresolved read that still has songs to
    /// show is a provisional verdict, which every other surface renders rather
    /// than reports; the player's re-check immediately before playback is what
    /// makes that safe. Reporting it here would put an error over a screenful of
    /// perfectly playable music.
    private static func loadTrouble(with results: LibraryResults) -> String? {
        guard !results.isResolved, results.items.isEmpty else { return nil }
        return Session.kidUnresolvedMessage
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
