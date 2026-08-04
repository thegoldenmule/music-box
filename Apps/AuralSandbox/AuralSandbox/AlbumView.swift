import CatalogKit
import FamilyStore
import SwiftUI

/// One album: the cover, who made it, and the songs on it in order.
///
/// A record is not a grid of pictures. Every track on it shares one piece of
/// artwork, so a tile grid repeats the same square a dozen times and asks a kid
/// to tell twelve identical images apart by the caption underneath — which is a
/// list, drawn expensively. The cover belongs at the top, once, and the songs
/// belong in a line under it.
///
/// Everything here has been through the policy engine, so a blocked track is
/// **absent** rather than greyed out — the rule ``BrowseView`` documents, and the
/// reason the track numbers come from the catalog instead of from counting rows.
struct AlbumView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel
    let album: CatalogItem

    @State private var tracks: [CatalogItem] = []
    /// Who is credited, filtered to the ones this kid may open. Empty until they
    /// land, and empty for good if the request failed — the header falls back to
    /// the artist name the album already carries.
    @State private var credits: [CatalogItem] = []
    @State private var isLoading = true
    @State private var failed = false
    /// How wide the credits row is allowed to be, so a short one can be centered
    /// in it. Zero until the first layout, which centers nothing and is the
    /// right thing to draw for the frame before the width is known.
    @State private var containerWidth: CGFloat = 0

    private var origin: PlaybackOrigin { .browse(album.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                contents
            }
            .padding(.vertical)
        }
        .navigationTitle(album.title)
        #if os(iOS)
            // Inline, because the large title would be the album's name a second
            // time directly above the cover that already says it.
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    @ViewBuilder
    private var contents: some View {
        if isLoading {
            ProgressView().padding(.top, 32)
        } else if failed {
            ContentUnavailableView {
                Label("That didn't work", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Let's try again.")
            } actions: {
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
                    // The fill, not the tint. `.borderedProminent` paints the
                    // accent *behind* a white label, and the two roles cannot be
                    // one colour: a value light enough to read as text on a dark
                    // background is too light to carry white on top of it. See
                    // `STYLE.md` §3.3.
                    .tint(Color(.kidAccentFill))
            }
        } else if tracks.isEmpty {
            ContentUnavailableView {
                Label("Nothing to play here", systemImage: "music.note")
            }
        } else {
            trackList
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            artwork
            Text(album.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            artists
            if let summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// **Clipped to a shape, never covered or composited onto** — the same
    /// reading of License §3.3.6(D) the tiles work under, and the reason there is
    /// no play button laid over the cover.
    private var artwork: some View {
        ArtworkImage(url: album.artworkURL) { image in
            image.resizable().aspectRatio(1, contentMode: .fit)
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "square.stack")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .frame(maxWidth: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .accessibilityHidden(true)
    }

    /// Who made it — as links, when the kid may follow them.
    ///
    /// Plain text is the fallback, not a lesser version of the same thing: it is
    /// what a record whose artist has been denied looks like, and the name stays
    /// because it is already the album's subtitle everywhere else in the app. A
    /// link that opens onto an empty page would be the worse answer.
    @ViewBuilder
    private var artists: some View {
        if credits.isEmpty {
            if let subtitle = album.subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        } else {
            // Horizontal rather than wrapped: a record with four credited
            // artists must not push its own track list off the screen.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(credits, id: \.id) { artist in
                        NavigationLink(value: KidRoute.container(artist)) { ArtistChip(artist: artist) }
                            .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal)
                // **`minWidth`, and it has to be measured.** One name sitting
                // hard left under a centered cover and a centered title reads as
                // a layout mistake, but `maxWidth: .infinity` does not fix it: a
                // horizontal `ScrollView` proposes an unspecified width along
                // its own axis, so the flexible frame collapses to the chips'
                // ideal width and nothing moves. A measured `minWidth` centers
                // the short case against the real container and still lets four
                // artists grow past it and scroll, which `containerRelativeFrame`
                // would not — that one *sets* the width and would strand the
                // overflow off-screen.
                .frame(minWidth: containerWidth)
            }
            // No rubber-banding on a single name, which is the tell that
            // something is a scroll view when it has no reason to be one.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background {
                GeometryReader { proxy in
                    // In the background, so measuring costs the row no height
                    // and cannot feed its own width back into the scroll view —
                    // the width here comes from the page, never from the chips.
                    Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(WidthKey.self) { containerWidth = $0 }
        }
    }

    /// How many songs, and how long the record runs.
    ///
    /// Both counted from what is actually on screen. On a filtered album that is
    /// a smaller record than the catalog's, which is the honest number here: it
    /// describes the list below it.
    private var summary: String? {
        guard !tracks.isEmpty else { return nil }
        let songs = "\(tracks.count) song\(tracks.count == 1 ? "" : "s")"

        let total = tracks.compactMap(\.duration).reduce(0, +)
        guard total > 0 else { return songs }
        let minutes = max(1, Int((total / 60).rounded()))
        return "\(songs) · \(minutes) min"
    }

    // MARK: - Tracks

    private var trackList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                if index > 0 {
                    Divider().padding(.leading, AlbumTrackMetrics.textInset)
                }
                AlbumTrackRow(item: track, albumArtist: album.subtitle) {
                    Task { await play(track) }
                } accessory: {
                    HeartButton(session: session, item: track, origin: origin)
                    AddToPlaylistButton(session: session, item: track, origin: origin)
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        failed = false

        // Started before the tracks are awaited, so the two requests overlap.
        // The header can fill in behind the list either way.
        async let credited = fetchCredits()

        do {
            let results = try await session.children(of: album.id)
            tracks = results.items
            // Filtered out of a surface the kid asked for, so still logged —
            // even though nothing here was ever rendered.
            session.logBlocked(results.blocked, origin: origin)
        } catch {
            failed = true
        }

        isLoading = false
        credits = await credited
    }

    /// Credits are decoration; the track list is the screen.
    ///
    /// So a failure here returns nothing rather than throwing: an album whose
    /// artist lookup timed out should still play, with the name it already has
    /// under the cover instead of a link.
    private func fetchCredits() async -> [CatalogItem] {
        (try? await session.artists(of: album.id)) ?? []
    }

    private func play(_ item: CatalogItem) async {
        await player.play(item, from: tracks.filter { $0.id.kind == .song }, origin: origin)
    }
}

/// Carries a measured width back up out of a `GeometryReader`.
///
/// A preference rather than writing `@State` from inside the reader's body:
/// that is a mutation during layout, and SwiftUI is entitled to complain about
/// it or to loop. This runs after layout, where a write is safe.
struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// An artist credit, as something to tap.
///
/// A circle and a name, because that is how an artist is drawn everywhere else in
/// the app — see `Tile.artworkShape`. Sized for a finger rather than for the text.
struct ArtistChip: View {
    let artist: CatalogItem

    private let imageSize: CGFloat = 32

    var body: some View {
        HStack(spacing: 8) {
            ArtworkImage(url: artist.artworkURL) { image in
                image.resizable().aspectRatio(1, contentMode: .fit)
            } placeholder: {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.mic")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .aspectRatio(1, contentMode: .fit)
            }
            .frame(width: imageSize, height: imageSize)
            .clipShape(Circle())

            Text(artist.title)
                .font(.headline)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.quaternary))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(artist.title))
        .accessibilityHint(Text("Opens"))
    }
}

/// A track row's measurements, and the one bit of formatting that goes with them.
///
/// Outside ``AlbumTrackRow`` because that type is generic, and a static on a
/// generic type cannot be named without supplying the parameter — the same reason
/// ``SongRowMetrics`` sits beside ``SongRow`` rather than inside it.
enum AlbumTrackMetrics {
    static let margin: CGFloat = 16
    static let numberWidth: CGFloat = 28
    static let gap: CGFloat = 12

    /// Where the text starts, and so where a separator should start too.
    static var textInset: CGFloat { margin + numberWidth + gap }

    /// `m:ss`, the way a track length is written on a record sleeve.
    static func length(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One line of a record: its number, its name, how long it runs, and the two
/// controls every song row in the app carries.
///
/// No artwork, unlike ``SongRow``. Twelve copies of the cover that is already at
/// the top of this screen is noise, and the number in its place is the thing a
/// track actually has that a search result does not.
///
/// **Three sibling controls, not one with others inside it** — the same rule
/// ``SongRow`` works under, because a button inside another button's label is
/// dead. The play target is the number, the title, and the gap out to the heart.
struct AlbumTrackRow<Accessory: View>: View {
    let item: CatalogItem

    /// The record's own credit, so a line that merely repeats it can be left off.
    /// `nil` shows every subtitle, which is the safe way round — a name too many
    /// beats a guest going unnamed.
    let albumArtist: String?

    let onPlay: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    /// Optional, so a row drawn where nobody put a player up simply never marks
    /// anything. See ``KidHomeView``.
    @Environment(KidPlayerModel.self) private var player: KidPlayerModel?

    private var isCurrent: Bool { player?.current?.item.id == item.id }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onPlay) {
                HStack(spacing: AlbumTrackMetrics.gap) {
                    number
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        // Only when it differs from the record's own credit —
                        // otherwise every line on an album repeats the name
                        // written twice above it already. This is what makes a
                        // guest on one track visible.
                        if let subtitle = item.subtitle, subtitle != albumArtist {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: AlbumTrackMetrics.gap)
                    if let duration = item.duration {
                        Text(AlbumTrackMetrics.length(duration))
                            .font(.subheadline)
                            // Monospaced digits so the column of times lines up
                            // instead of shifting a point per digit.
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilityLabel))
            // What the mark says, for somebody who cannot see it.
            .accessibilityValue(isCurrent ? Text("Playing") : Text(""))
            .accessibilityHint(Text("Plays"))

            accessory()
        }
        .padding(.horizontal, AlbumTrackMetrics.margin)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var number: some View {
        // **The mark stands where the number does.** A track number is the most
        // disposable thing in the row — it names a position a kid is not
        // counting — so the one row that has something better to say puts it
        // there. It is also the column the eye is already scanning down, and it
        // is what the Music app does with the same slot.
        if isCurrent {
            NowPlayingMark(isAnimating: player?.isPlaying == true)
                .frame(width: AlbumTrackMetrics.numberWidth, alignment: .trailing)
        } else if let trackNumber = item.trackNumber {
            Text("\(trackNumber)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: AlbumTrackMetrics.numberWidth, alignment: .trailing)
        } else {
            // A record whose numbering the catalog withheld still needs the
            // column, or its rows sit under a different left edge than its
            // neighbours'.
            Image(systemName: "music.note")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: AlbumTrackMetrics.numberWidth, alignment: .trailing)
        }
    }

    /// Spoken rather than read off the screen: VoiceOver says "three colon zero
    /// four" for `3:04` otherwise, and "1" for a track number is a bare digit
    /// with no idea what it counts.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let trackNumber = item.trackNumber { parts.append("Track \(trackNumber)") }
        parts.append(item.title)
        if let subtitle = item.subtitle { parts.append(subtitle) }
        if let duration = item.duration {
            let total = Int(duration.rounded())
            let minutes = total / 60
            let seconds = total % 60
            var spoken: [String] = []
            if minutes > 0 { spoken.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
            if seconds > 0 { spoken.append("\(seconds) second\(seconds == 1 ? "" : "s")") }
            if !spoken.isEmpty { parts.append(spoken.joined(separator: " ")) }
        }
        return parts.joined(separator: ", ")
    }
}
