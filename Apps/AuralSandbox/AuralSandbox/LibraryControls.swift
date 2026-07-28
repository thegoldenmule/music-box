import CatalogKit
import FamilyStore
import KidLibrary
import SwiftUI

/// The heart.
///
/// Filled and outline, no count, no animation a kid has to sit through. It reads
/// the same on a song, an album and an artist even though the primitive
/// underneath differs by kind — that difference is the seam's problem and never
/// the kid's.
///
/// **Never drawn on the artwork.** The standing rule is clipping yes,
/// compositing never, and a heart burned onto Apple's pixels is exactly what
/// that forbids. So it sits in the text area of a tile and beside the play
/// button on a row.
struct HeartButton: View {
    @Bindable var session: Session
    let item: CatalogItem
    let origin: PlaybackOrigin

    /// Big enough for a finger that is not very accurate yet, without pushing
    /// the title it sits beside off the line.
    static let size: CGFloat = 28

    private var isOn: Bool { session.isFavorite(item.id) }

    var body: some View {
        Button {
            // The failure message is discarded on purpose, and the heart is
            // still honest: it draws from rows re-read after the write, so a
            // write that did not land leaves it exactly as it was. Nothing about
            // a store failing is a thing to put in front of a six-year-old.
            Task { _ = await session.toggleFavorite(item, origin: origin) }
        } label: {
            Image(systemName: isOn ? "heart.fill" : "heart")
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Remove from your library" : "Add to your library")
    }
}

/// Put this song on a playlist.
///
/// A menu of the kid's playlists plus one way to make another, which is what
/// makes "songs are added from anywhere a song appears" true without a screen
/// per gesture. Absent when there is nothing to add — a menu whose only entry is
/// "new" is a button wearing a menu's clothes, so that case is a button.
struct AddToPlaylistButton: View {
    @Bindable var session: Session
    let item: CatalogItem
    let origin: PlaybackOrigin

    @State private var isNaming = false

    var body: some View {
        Group {
            if session.playlists.isEmpty {
                Button { isNaming = true } label: { glyph }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(session.playlists) { playlist in
                        Button(playlist.name) { add(to: playlist.handle) }
                    }
                    Divider()
                    Button("New playlist…") { isNaming = true }
                } label: {
                    glyph
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .accessibilityLabel("Add to a playlist")
        .sheet(isPresented: $isNaming) {
            NamePlaylistSheet(session: session, songs: [item])
        }
    }

    private var glyph: some View {
        Image(systemName: "text.badge.plus")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: HeartButton.size, height: HeartButton.size)
            .contentShape(Rectangle())
    }

    private func add(to handle: PlaylistHandle) {
        Task { _ = await session.addToPlaylist(handle, song: item, origin: origin) }
    }
}

/// Naming a playlist. A keyboard and one field.
///
/// The name is free text a child typed. It reaches their Apple Music library and
/// the parent's report, which is worth knowing about the field rather than
/// discovering later.
struct NamePlaylistSheet: View {
    @Bindable var session: Session

    /// Songs to start it with. Empty when a kid is making an empty one to fill
    /// later, which is the commoner case from the shelf.
    var songs: [CatalogItem] = []

    /// Set when renaming instead of creating.
    var renaming: PlaylistHandle?

    var initialName: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var trouble: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .font(.title3)
                if let trouble {
                    Text(trouble).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(renaming == nil ? "New playlist" : "Rename")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { name = initialName }
        }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let name = trimmed
        Task {
            let failure =
                if let renaming {
                    await session.renamePlaylist(renaming, to: name)
                } else {
                    await session.createPlaylist(named: name, songs: songs)
                }
            if let failure {
                trouble = failure
            } else {
                dismiss()
            }
        }
    }
}

/// A tile, with a heart in its text area and the right tap behaviour for its
/// kind.
///
/// The heart is a **sibling** of the tap target rather than a control inside it.
/// Nesting one button in another's label leaves the inner one dead — the outer
/// swallows the tap — and a heart that does nothing is worse than no heart. So
/// the tile is drawn with a gap reserved on its subtitle line and the heart is
/// laid into that gap on top.
struct TileCell: View {
    @Bindable var session: Session
    let item: CatalogItem
    let origin: PlaybackOrigin
    let onPlay: (CatalogItem) -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                // A song plays where it stands; everything else opens. Deciding
                // it here rather than in a tap handler means the destination is
                // the enclosing stack's, so browsing nests without every screen
                // owning a path.
                if item.id.kind == .song {
                    Button { onPlay(item) } label: { Tile(item: item, hasHeart: true) }
                } else {
                    NavigationLink(value: item) { Tile(item: item, hasHeart: true) }
                }
            }
            .buttonStyle(.plain)

            HeartButton(session: session, item: item, origin: origin)
                .padding(.leading, Tile.padding)
                .padding(.bottom, Tile.padding)
        }
        .contextMenu {
            if item.id.kind == .song {
                PlaylistMenuItems(session: session, item: item, origin: origin)
            }
        }
    }
}

/// The add-to-playlist half of a context menu, so a song reached as a tile has
/// the same reach as one reached as a row.
struct PlaylistMenuItems: View {
    @Bindable var session: Session
    let item: CatalogItem
    let origin: PlaybackOrigin

    var body: some View {
        ForEach(session.playlists) { playlist in
            Button("Add to \(playlist.name)") {
                Task { _ = await session.addToPlaylist(playlist.handle, song: item, origin: origin) }
            }
        }
    }
}
