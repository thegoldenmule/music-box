import CatalogKit
import FamilyStore
import PolicyEngine
import SwiftUI

/// One tile on the grown-up shelf.
///
/// Wraps ``TileCell`` for anything with a catalog identifier and draws its own
/// card for a snapshot playlist, which has none. The dismiss affordance is the
/// only thing both halves share, and it is only there for tiles that came from a
/// suggestion — an allow-list item on the same shelf has nothing to dismiss, and
/// a kid does not get to edit their parent's list.
struct SuggestedTileCell: View {
    @Bindable var session: Session
    let tile: SuggestedTile
    let onPlay: (CatalogItem) -> Void
    let onDismiss: (SuggestionRow) -> Void

    /// Whether to hold the note's two lines open even on a tile with no note.
    ///
    /// Set for a whole shelf at once. With the note above the artwork, a tile
    /// without one would otherwise start where another tile's note starts, and
    /// a row of covers at two different heights reads as a mistake rather than
    /// as a difference in what the parent wrote.
    var reservesNoteSpace = false

    @State private var confirmingDismiss = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Above the artwork: it is the reason the tile is on the shelf, and
            // under the cover it read as a caption on the music rather than as
            // the sentence that came first.
            //
            // Inset to match, because ``Tile`` pads its own contents and the
            // note is not inside it. Flush left it lined up with the section
            // header instead of with the cover it belongs to, which made one
            // album's note read as a subtitle for the whole shelf.
            if reservesNoteSpace || note != nil {
                SuggestionNote(text: note, reservesSpace: reservesNoteSpace)
                    .padding(.horizontal, Tile.padding)
            }

            switch tile {
            case .item(let item):
                TileCell(
                    session: session,
                    item: item,
                    origin: .suggestion,
                    onPlay: onPlay,
                    onDismiss: row != nil ? { confirmingDismiss = true } : nil
                )
            case .snapshotPlaylist(let playlist):
                ZStack(alignment: .topTrailing) {
                    NavigationLink(value: KidRoute.home(.suggestedPlaylist(playlist.id))) {
                        SuggestedPlaylistTile(row: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("No thanks", systemImage: "xmark", role: .destructive) {
                            confirmingDismiss = true
                        }
                    }

                    DismissButton { confirmingDismiss = true }
                        .padding(Tile.padding)
                }
            }
        }
        // **Asked, not assumed.** The X sits on the artwork of a shelf a small
        // child scrolls with their whole hand, one tap from taking something
        // away — and what it takes away is not only the tile but the reach that
        // came with it. A tap that costs that much should have to be meant
        // twice.
        //
        // Here rather than in each screen that draws these tiles, so the shelf
        // and the grid behind it cannot end up asking differently, or one of
        // them not asking at all.
        //
        // **The button answers the question it is under.** This first read
        // "Take this off your shelf?" over a button saying "No thanks" — which
        // is the kid declining the removal, not asking for it, and the
        // destructive tint made it worse by looking like the dangerous choice
        // whichever way you parsed it. A question and its affirmative have to
        // use the same word, and the word is the one on the button that started
        // this.
        .confirmationDialog(
            "Remove this?",
            isPresented: $confirmingDismiss,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let row { onDismiss(row) }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This takes it out of your suggestions.")
        }
    }

    /// The parent's sentence, where they wrote one.
    ///
    /// Drawn on the tile rather than folded into the subtitle, which is the
    /// artist and is what a kid uses to tell two tiles apart. It is also the
    /// only part of this shelf that is a person talking rather than a catalog
    /// describing itself, and burying it in a detail screen — which is where it
    /// was — meant nobody read it.
    private var note: String? { row?.displayNote }

    /// The suggestion behind this tile, whichever shape it is.
    private var row: SuggestionRow? {
        switch tile {
        case .item(let item): row(for: item)
        case .snapshotPlaylist(let playlist): playlist
        }
    }

    /// The suggestion behind a catalog tile, if there is one.
    ///
    /// The shelf is a merge — suggestions first, then the allow list — and the
    /// two halves are indistinguishable to look at on purpose. They are not
    /// indistinguishable to touch: passing on something a parent suggested is
    /// the kid's to do, and deleting from the allow list is not. An allow-list
    /// tile has no row here, so it gets no note and no dismiss button.
    private func row(for item: CatalogItem) -> SuggestionRow? {
        session.suggestions.first { $0.catalogID == item.id }
    }
}

/// A parent's line about why they picked something.
///
/// Quoted and in the parent's voice, so it reads as somebody saying a thing
/// rather than as more catalog metadata — which is the only reason it is on the
/// shelf at all.
struct SuggestionNote: View {
    let text: String?

    /// Holds two lines open whether or not there is anything in them. What keeps
    /// a shelf's covers on one line — see ``SuggestedTileCell/reservesNoteSpace``.
    var reservesSpace = false

    /// What a reserved, empty note costs a tile. The shelf adds it to its own
    /// height so the two cannot disagree about how tall a tile with a note is.
    static let reservedHeight: CGFloat = 34

    var body: some View {
        Text(text.map { "“\($0)”" } ?? "")
            .font(.caption)
            .italic()
            .foregroundStyle(.secondary)
            .lineLimit(2, reservesSpace: reservesSpace)
            .fixedSize(horizontal: false, vertical: true)
            // Bottom-aligned so a one-line note sits against the artwork it is
            // about, rather than floating with the gap under it.
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .accessibilityHidden(text == nil)
            .accessibilityLabel(text.map { "Your grown-up says: \($0)" } ?? "")
    }
}

/// A suggested playlist that only exists here.
///
/// A card rather than a tile with artwork, for the reason ``PlaylistCard`` is
/// one: a playlist has no artwork of its own, and borrowing the first song's
/// would be compositing a name onto Apple's pixels. Sized to match the tiles
/// beside it so a mixed shelf still lines up.
struct SuggestedPlaylistTile: View {
    let row: SuggestionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
            .aspectRatio(1, contentMode: .fit)

            Text(row.displayName)
                .font(.headline)
                .lineLimit(2, reservesSpace: true)
            Text(row.entries.count == 1 ? "1 song" : "\(row.entries.count) songs")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Tile.padding)
        .background { RoundedRectangle(cornerRadius: 16).fill(.quaternary) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.displayName), playlist"))
        .accessibilityHint(Text("Opens"))
    }
}

/// The grown-up shelf, sideways.
struct SuggestedShelf: View {
    @Bindable var session: Session
    let tiles: [SuggestedTile]
    let onPlay: (CatalogItem) -> Void
    let onDismiss: (SuggestionRow) -> Void

    private let tileWidth: CGFloat = 150

    /// Whether any suggestion on this shelf carries a note.
    ///
    /// Asked of the suggestions rather than of `tiles`, which also carries the
    /// allow-list tail — those never have notes, and they always sit behind the
    /// ones that might.
    private var hasNotes: Bool {
        session.suggestions.contains { $0.displayNote != nil }
    }

    /// Room for the note above the artwork, held open for the whole shelf so
    /// every cover starts at the same height.
    private var noteHeight: CGFloat {
        hasNotes ? SuggestionNote.reservedHeight + 6 : 0
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(tiles) { tile in
                    SuggestedTileCell(
                        session: session,
                        tile: tile,
                        onPlay: onPlay,
                        onDismiss: onDismiss,
                        reservesNoteSpace: hasNotes
                    )
                    .frame(width: tileWidth)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: tileWidth + 84 + noteHeight)
    }
}

/// Everything the grown-up put there, behind the shelf's chevron.
struct SuggestionsView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel

    @State private var tiles: [SuggestedTile] = []
    @State private var isLoading = true
    @State private var trouble: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        Group {
            if isLoading && tiles.isEmpty {
                ProgressView()
            } else if let trouble {
                ContentUnavailableView("Can't load this", systemImage: "wifi.slash", description: Text(trouble))
            } else if tiles.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "gift",
                    description: Text("When your grown-up picks something out for you, it shows up here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(tiles) { tile in
                            SuggestedTileCell(
                                session: session,
                                tile: tile,
                                onPlay: play,
                                onDismiss: dismiss,
                                // Grid rows line up for the same reason a shelf
                                // does, and by the same measure.
                                reservesNoteSpace: session.suggestions.contains {
                                    $0.displayNote != nil
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("From your grown-up")
        .task { await load() }
        // The shelf is a projection of rows this screen can change, so it is
        // re-read rather than patched: dismissing one tile can also take the
        // allow it granted, and anything else on screen that depended on that
        // allow has to go with it.
        .onChange(of: session.suggestions) { Task { await load() } }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tiles = try await session.grownUpShelf()
            trouble = nil
        } catch {
            trouble = Session.message(for: error)
        }
    }

    private func play(_ item: CatalogItem) {
        Task { await player.play(item, from: tiles.compactMap(\.playableItem), origin: .suggestion) }
    }

    private func dismiss(_ row: SuggestionRow) {
        if let failure = session.dismissSuggestion(row) { trouble = failure }
    }
}

/// One suggested playlist, as the kid sees it.
///
/// Reads entirely from rows already in memory — the parent resolved these when
/// they suggested it, and they carry their own lineage — so opening one costs no
/// request and works with the network down.
struct SuggestedPlaylistView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel
    let local: UUID

    private var row: SuggestionRow? { session.suggestedPlaylist(local) }
    private var songs: [CatalogItem] { session.suggestedPlaylistSongs(local) }

    var body: some View {
        Group {
            if let row {
                if songs.isEmpty {
                    ContentUnavailableView(
                        "Nothing to play here",
                        systemImage: "music.note.list",
                        description: Text("Ask your grown-up about this one.")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if let note = row.note, !note.isEmpty {
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .padding(.bottom, 8)
                        }
                        SongList(session: session, items: songs, origin: origin, onPlay: play)
                    }
                }
            } else {
                // The parent took it back while the kid was inside it.
                ContentUnavailableView("This one's gone", systemImage: "music.note.list")
            }
        }
        .navigationTitle(row?.displayName ?? "Playlist")
    }

    private var origin: PlaybackOrigin { .suggestedPlaylist(local) }

    private func play(_ item: CatalogItem) {
        Task { await player.play(item, from: songs, origin: origin) }
    }
}

extension SuggestedTile {
    /// The item to hand the player, for the tiles that are one.
    ///
    /// A snapshot playlist is not: it is opened, and the screen behind it hands
    /// over its own songs.
    var playableItem: CatalogItem? {
        if case .item(let item) = self, item.id.kind == .song { return item }
        return nil
    }
}
