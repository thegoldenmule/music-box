import CatalogKit
import FamilyStore
import SwiftUI

/// What is playing, and the controls that go with it.
///
/// Play, pause, skip, and the heart. No shuffle, no repeat, no next-up list —
/// the bar itself stays as narrow as it ever was. Tapping the artwork or the
/// title opens ``NowPlayingView``, which is the same controls at a bigger size,
/// a scrubber, links to the record and the artist, and the way onto a playlist.
///
/// **What is not here is a space decision, not a policy one.** A phone gives
/// this row one line, and every glyph on it is a word of the title the kid
/// cannot read. So the title takes the room and the two things that survived
/// the cut are the ones a kid reaches for mid-song.
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

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.title).font(.headline).lineLimit(1)
                                if let subtitle = entry.item.subtitle {
                                    Text(subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            // Claims the whole row rather than sizing to the
                            // words, which is both the tap target and the
                            // point: a bar this narrow spends every point it
                            // has on the title, and the title is the only
                            // thing here a kid cannot work out from a glyph.
                            //
                            // No caret. It was the one cue that the bar opens,
                            // and it cost more room than it bought — the
                            // artwork and the title are the target, and a kid
                            // who taps a picture of the song they are hearing
                            // is not guessing.
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the player")
                    .accessibilityHint(entry.item.title)

                    // Keeping what is playing. Not a door: it acts on the song
                    // already in the bar rather than leading anywhere, which is
                    // the line this bar draws.
                    //
                    // Adding to a playlist lives on ``NowPlayingView`` alone
                    // now. The bar is one row on a phone and four controls do
                    // not fit beside a title worth reading; the screen behind
                    // one tap has room for both, and is still one of the two
                    // places the spec says a playlist gets made.
                    HeartButton(session: session, item: entry.item, origin: entry.origin)

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
