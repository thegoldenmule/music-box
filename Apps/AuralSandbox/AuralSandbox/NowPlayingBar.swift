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

    #if os(iOS)
    /// Shared with ``NowPlayingView``, because opening the player is one
    /// movement that starts here and ends there and a finger may turn back
    /// halfway through it.
    ///
    /// From the environment for the same reason ``KidRouter`` is: eight screens
    /// draw this bar, and threading a parameter through all of them to reach the
    /// one row at the bottom is an initializer argument per screen forever. Nil
    /// wherever nobody put one up, and the drag is simply absent there — the tap
    /// is not, because it never needed anything.
    @Environment(PlayerExpansion.self) private var expansion: PlayerExpansion?
    #else
    @State private var isExpanded = false
    #endif

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
                    // A tap and not a `Button`, and that is what makes the drag
                    // possible at all: a button takes the touch the instant it
                    // lands and never gives it back, so the artwork and the
                    // title — which is to say the whole left side of the bar,
                    // and the only part of it worth putting a thumb on — was
                    // the one place a pull upward could not begin. A tap
                    // gesture gives way the moment the finger moves.
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
                        // Claims the whole row rather than sizing to the words,
                        // which is both the tap target and the point: a bar this
                        // narrow spends every point it has on the title, and the
                        // title is the only thing here a kid cannot work out
                        // from a glyph.
                        //
                        // No caret. It was the one cue that the bar opens, and
                        // it cost more room than it bought — the artwork and
                        // the title are the target, and a kid who taps a
                        // picture of the song they are hearing is not guessing.
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openPlayer() }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
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
            #if os(iOS)
            .contentShape(Rectangle())
            .gesture(expandDrag)
            #else
            // On the Mac a sheet is what "the whole window" means, there is no
            // finger to follow, and the bar is a row you click.
            .sheet(isPresented: $isExpanded) {
                NowPlayingView(session: session, player: player)
            }
            #endif
        }
    }

    /// The tap, unchanged in what it does and now one of two ways to do it.
    private func openPlayer() {
        #if os(iOS)
        expansion?.open()
        #else
        isExpanded = true
        #endif
    }

    #if os(iOS)
    /// Dragging the bar up brings the player up with the finger, and is the
    /// other half of dragging it back down again.
    ///
    /// The tap on the artwork and the title is untouched and is still the way
    /// this is meant to be found; a drag is for the hand that has already
    /// learned the gesture on some other app.
    ///
    /// Downward is ignored outright rather than resisted — see
    /// ``PlayerExpansion/pull(by:)``. Below the bar is the bottom of the screen,
    /// and a bar that dips reads as a second thing to pull on.
    ///
    /// `.gesture`, so the heart, play and skip beside the title keep their taps.
    ///
    /// Global space, like the one on the way back down: the bar does not move,
    /// but the two halves of one movement should be measured the same way, and
    /// the player this is dragging very much does.
    private var expandDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { expansion?.pull(by: $0.translation.height) }
            .onEnded { expansion?.release(projected: $0.translation.height + $0.velocity.height / 4) }
    }
    #endif
}
