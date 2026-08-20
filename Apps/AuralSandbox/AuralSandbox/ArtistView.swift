import CatalogKit
import FamilyStore
import SwiftUI

/// One artist: who they are, their records, and the songs they are known for.
///
/// Two lists rather than one, because they are chosen between differently. An
/// album is picked by its cover, so it is a tile and the covers sit in a row
/// wide enough to flick through; a song is picked by its name, so it is a line of
/// text. A grid of both would make the songs look like albums a kid cannot open.
///
/// Singles are left out of the shelf on purpose — see ``albums``.
///
/// Everything here has been through the policy engine, so a blocked record or
/// track is **absent** rather than greyed out, and the blocked half still reaches
/// the parent's report.
struct ArtistView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel
    let artist: CatalogItem

    @State private var albums: [CatalogItem] = []
    @State private var songs: [CatalogItem] = []
    @State private var related: [CatalogItem] = []
    @State private var isLoading = true
    @State private var failed = false

    private var origin: PlaybackOrigin { .browse(artist.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                contents
            }
            .padding(.vertical)
        }
        .navigationTitle(artist.title)
        #if os(iOS)
            // Inline, because a large title would be the artist's name a second
            // time directly above the picture that already says it.
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    // MARK: - Header

    /// The picture, the name, and the one thing there is to do with an artist
    /// besides listening to them.
    ///
    /// Centered, unlike everything below it: this is the only block on the page
    /// that is about the whole page rather than a row in it.
    private var header: some View {
        VStack(spacing: 16) {
            artwork
            Text(artist.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            FavoriteButton(session: session, item: artist, origin: origin)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }

    /// A circle, the way every music app draws a person — and the way this app
    /// already draws one on a tile. **Clipped, never composited onto**: the
    /// reading of License §3.3.6(D) the rest of the app works under.
    private var artwork: some View {
        ArtworkImage(url: artist.artworkURL) { image in
            image.resizable().aspectRatio(1, contentMode: .fit)
        } placeholder: {
            // Plenty of artists have no image in the catalog at all, so this is
            // what their page looks like for good rather than a flicker on the
            // way to a photograph.
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.mic")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .frame(width: 180, height: 180)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    // MARK: - Body

    @ViewBuilder
    private var contents: some View {
        if isLoading {
            centered { ProgressView() }
        } else if failed {
            centered {
                ContentUnavailableView {
                    Label("That didn't work", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Let's try again.")
                } actions: {
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        // The fill rather than the tint — see ``AlbumView``.
                        .tint(Color(.kidAccentFill))
                }
            }
        } else if albums.isEmpty && songs.isEmpty {
            centered {
                ContentUnavailableView {
                    Label("Nothing to play here", systemImage: "music.note")
                }
            }
        } else {
            if !albums.isEmpty {
                section("Albums") {
                    TileShelf(session: session, items: albums, origin: origin) { item in
                        Task { await play(item, from: albums) }
                    }
                }
            }
            if !songs.isEmpty {
                section("Songs") {
                    SongRows(session: session, items: songs, origin: origin) { item in
                        Task { await play(item, from: songs) }
                    }
                }
            }
            // Last, and only under a page that had something on it. An artist
            // with nothing playable is not a page to hop off — the empty state
            // above catches that case before this one can draw.
            if !related.isEmpty {
                section("Similar artists") {
                    TileShelf(session: session, items: related, origin: origin) { item in
                        Task { await play(item, from: related) }
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            content()
        }
    }

    private func centered<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        failed = false

        // Concurrent, because they are two round trips to the same artist and
        // running them in series would make the page take twice as long to say
        // anything.
        async let records = session.children(of: artist.id)
        async let known = session.topSongs(of: artist.id)
        // Decoration, the way an album's credits are: a shelf that fails is a
        // shelf that does not draw. Letting it throw would turn a page full of
        // playable records into "That didn't work" over a shelf nobody asked
        // for.
        async let adjacent = (try? session.similarArtists(of: artist.id)) ?? .empty

        do {
            let (recordResults, songResults, relatedResults) = try await (
                records, known, adjacent
            )

            albums = recordResults.items.filter { !$0.isSingleRelease }
            songs = songResults.items
            related = relatedResults.items

            // Both halves logged, including the singles' worth of blocks. A
            // record filtered out of a surface the kid asked for is still a
            // block the parent's report wants, whether or not the shelf that
            // would have shown it ends up showing anything.
            session.logBlocked(
                recordResults.blocked + songResults.blocked + relatedResults.blocked,
                origin: origin
            )
        } catch {
            failed = true
        }

        isLoading = false
    }

    /// Songs play; an album opens, which ``TileCell`` handles itself. The queue
    /// is the list the tap came from, so a song from the shelf never queues up
    /// the row below it.
    private func play(_ item: CatalogItem, from list: [CatalogItem]) async {
        await player.play(item, from: list.filter { $0.id.kind == .song }, origin: origin)
    }
}
