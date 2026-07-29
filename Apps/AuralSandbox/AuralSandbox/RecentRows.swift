import CatalogKit
import SwiftUI

/// The Recent page: one row per arrival, whatever kind it was.
///
/// A list rather than a grid, unlike the shelf it sits behind. The shelf is a
/// handful of tiles a kid picks between by sight; this is the long form, and
/// reading a long list is reading titles. That is the same reasoning
/// ``SongList`` carries — it just has to hold records and artists too now.
///
/// **Songs keep the song row.** A mixed list where the songs looked different
/// from the songs everywhere else in the app would be a third treatment of the
/// same thing, so this reuses ``SongRow`` outright and adds a sibling for the
/// kinds that open rather than play.
struct RecentRows: View {
    @Bindable var session: Session
    let items: [CatalogItem]
    let onPlay: (CatalogItem) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            // Indexed for the separator, so it is decided by position rather
            // than by comparing identifiers — the same reason ``SongRows`` does
            // it this way.
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, SongRowMetrics.textInset)
                }
                if item.id.kind == .song {
                    SongRow(item: item) {
                        onPlay(item)
                    } accessory: {
                        HeartButton(session: session, item: item, origin: .home)
                        AddToPlaylistButton(session: session, item: item, origin: .home)
                    }
                } else {
                    ContainerRow(session: session, item: item)
                }
            }
        }
    }
}

/// One record, artist or playlist, as a row.
///
/// Deliberately shaped like ``SongRow`` — same artwork size, same inset, same
/// two lines of text — so a mixed list reads as one list rather than as two
/// stitched together. What differs is what the row *does*, and the two marks
/// that say so: a circle for an artist, and a caret instead of a play triangle.
///
/// A `NavigationLink` rather than a button with a tap handler, so the
/// destination is the enclosing stack's and this row needs to know nothing about
/// where it is being drawn. The same call ``TileCell`` makes, for the same
/// reason.
struct ContainerRow: View {
    @Bindable var session: Session
    let item: CatalogItem

    /// Where this row goes. `nil` — the default — is the catalog page for the
    /// thing itself, which is what every caller but the library browser wants.
    ///
    /// Optional rather than defaulted to `.container(item)` because a stored
    /// property cannot refer to another one; ``destination`` closes the gap.
    ///
    /// The browser's columns are the exception and the reason this exists at
    /// all: tapping an artist there opens *their albums in the library* rather
    /// than their catalog page, and the row is otherwise identical. A second row
    /// type would have been these forty lines again with one value changed.
    var route: KidRoute?

    private var destination: KidRoute { route ?? .container(item) }

    var body: some View {
        HStack(spacing: 4) {
            NavigationLink(value: destination) {
                HStack(spacing: SongRowMetrics.gap) {
                    artwork
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(item.subtitle ?? kindName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: SongRowMetrics.gap)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
            )
            .accessibilityHint(Text("Opens"))

            // The heart sits where a song's does, so the trailing edge of the
            // list is one column rather than two. An artist can be favorited
            // exactly like anything else.
            HeartButton(session: session, item: item, origin: .home)

            // A caret where a song has its play triangle. Same size, same
            // column, opposite meaning — which is the whole of what a kid needs
            // to tell these rows apart at a glance.
            Image(systemName: "chevron.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: HeartButton.size, height: HeartButton.size)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SongRowMetrics.margin)
        .padding(.vertical, 10)
    }

    /// What the second line says when the catalog gave no subtitle — which is
    /// every artist, where a subtitle would only repeat the title.
    private var kindName: String {
        switch item.id.kind {
        case .album: "Album"
        case .artist: "Artist"
        case .playlist: "Playlist"
        case .song: "Song"
        }
    }

    /// Clipped, never covered — see ``Tile/artwork``. A circle for an artist,
    /// the way every music app draws a person, inside the same square box as
    /// everything else so the column of artwork stays a column.
    private var artwork: some View {
        ArtworkImage(url: item.artworkURL) { image in
            image.resizable().aspectRatio(1, contentMode: .fit)
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: placeholderGlyph).foregroundStyle(.tertiary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .frame(width: SongRowMetrics.artworkSize, height: SongRowMetrics.artworkSize)
        .clipShape(
            item.id.kind == .artist
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(cornerRadius: 8))
        )
    }

    /// A steady sight rather than a flicker on the way to artwork: plenty of
    /// artists have no image in the catalog at all.
    private var placeholderGlyph: String {
        switch item.id.kind {
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        default: "square.stack"
        }
    }
}
