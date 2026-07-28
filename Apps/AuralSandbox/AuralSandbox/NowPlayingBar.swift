import CatalogKit
import FamilyStore
import SwiftUI

/// What is playing, and the controls that go with it.
///
/// Play, pause, skip. No shuffle, no repeat, no next-up list — the bar itself
/// stays as narrow as it ever was. Tapping the song opens ``NowPlayingView``,
/// which is the same controls at a bigger size, a scrubber, and links to the
/// record and the artist.
///
/// Skip stops at the end of the queue rather than finding something else to
/// play. Autoplay past the end is the fourth MusicKit affordance this app never
/// uses, and the queue living in ``KidPlayerModel`` is what makes that true by
/// construction rather than by remembering to switch it off.
struct NowPlayingBar: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel

    @State private var isExpanded = false

    var body: some View {
        if let entry = player.current {
            VStack(spacing: 0) {
                if let message = player.message {
                    // The only block a kid is ever shown, and only for a track
                    // filtered out of something they were already playing.
                    // Plain words, no error code, and no mention of the rule.
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                HStack(spacing: 16) {
                    // The song is a **sibling** of the controls, not a wrapper
                    // around them: nesting a button inside another's label
                    // leaves the inner one dead, and a play button that does
                    // nothing is worse than no bar at all. So the whole left
                    // side opens the full-screen player and the glyphs to its
                    // right keep their own taps.
                    Button { isExpanded = true } label: {
                        HStack(spacing: 16) {
                            ArtworkImage(url: entry.item.artworkURL) { image in
                                image.resizable()
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading) {
                                Text(entry.item.title).font(.headline).lineLimit(1)
                                if let subtitle = entry.item.subtitle {
                                    Text(subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            // The only cue that the bar opens. A kid does not
                            // discover a gesture nothing points at.
                            Image(systemName: "chevron.up")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the player")
                    .accessibilityHint(entry.item.title)

                    // Keeping what is playing, and putting it on a playlist.
                    // Not doors: both act on the song already in the bar rather
                    // than leading anywhere, which is the line this bar draws.
                    // It is also the screen the spec names as one of the two
                    // places a playlist gets made.
                    HeartButton(session: session, item: entry.item, origin: entry.origin)
                    AddToPlaylistButton(
                        session: session,
                        item: entry.item,
                        origin: entry.origin
                    )

                    Button {
                        Task { await player.togglePlayPause() }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        Task { await player.skip() }
                    } label: {
                        Image(systemName: "forward.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip")
                }
                .padding()
            }
            .background(.bar)
            // `fullScreenCover` is iOS-only, and on the Mac a sheet is what
            // "the whole window" means. Same view either way.
            #if os(iOS)
            .fullScreenCover(isPresented: $isExpanded) {
                NowPlayingView(session: session, player: player)
            }
            #else
            .sheet(isPresented: $isExpanded) {
                NowPlayingView(session: session, player: player)
            }
            #endif
        }
    }
}
