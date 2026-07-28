import CatalogKit
import FamilyStore
import Observation
import SwiftUI

/// The now playing bar, opened up.
///
/// Same song, a bigger picture, the words at a size a kid can read across a
/// room, and two things the bar does not have: the scrubber, and a way to the
/// record and the artist.
///
/// **Neither link is a control.** The record is reached by tapping the cover
/// and the artist by tapping their name, so nothing was added to the screen to
/// carry them — the two biggest things already on it became the two links. A
/// kid who taps a picture of a record and gets the record has not been taught
/// anything new.
///
/// **Where the line is now.** The scrubber reaches nowhere the verdict that
/// started this track did not already allow, so it is not a door in any sense.
/// The links are: they go somewhere. What makes them safe is not that they are
/// small but that they land on ``AlbumView`` and ``ArtistView`` — two screens
/// already inside the kid's stack, reachable from search and from every shelf,
/// and filtered by the policy engine on arrival like everything else. Both are
/// resolved through ``Session/resolveAllowed(_:)`` before they are drawn, so a
/// denied artist is a plain name and a denied record is a picture that does
/// nothing when tapped, rather than a link onto an empty page. See ``Lineage``.
///
/// Still absent, and not by oversight: autoplay, a next-up list, radio,
/// "more like this", lyrics, and share. Recommendations and stations reach
/// unvetted material, which the album a song is already playing from does not.
/// This is the screen a child will be left alone with the longest, so the
/// question for anything added to it is where it leads and who judged what is
/// there.
struct NowPlayingView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel

    /// Whether any of this can be seen.
    ///
    /// The player is never taken out of the hierarchy on iOS — see
    /// ``ExpandedPlayer`` — so "closed" is a position rather than an absence,
    /// and work that only matters on screen has to be told. Defaulted, because
    /// the Mac presents this in a sheet and a sheet is only ever up.
    var isShowing = true

    @Environment(KidRouter.self) private var router: KidRouter?
    #if os(iOS)
    @Environment(PlayerExpansion.self) private var expansion: PlayerExpansion?
    #else
    @Environment(\.dismiss) private var dismiss
    #endif

    /// The record and the artist, once resolved and once the engine has had its
    /// say. Held here rather than in a child view because two parts of the
    /// layout need it — the cover and the name — and they are not siblings.
    @State private var lineage = Lineage()

    var body: some View {
        Group {
            if let entry = player.current {
                content(for: entry)
            } else {
                // The queue ran out while this was open. Nothing to show, and a
                // kid staring at a blank screen with no way back is worse than
                // being returned to what they were doing.
                //
                // Only when it is up: on iOS this view outlives its own closing
                // and is sitting off the bottom of the screen most of the time,
                // where "the queue is empty" is the ordinary state of things and
                // not something that happened to anybody.
                Color.clear.onAppear { if isShowing { close() } }
            }
        }
        #if os(iOS)
        // The whole screen, and not merely the parts of it that happen to have
        // something drawn on them. A container's hit region is the union of its
        // children's, so without this the drag answers on the title and the
        // clock and nowhere else — the margins, the gaps and both spacers are
        // holes a finger falls through, which is a gesture that works where a
        // kid is not touching and fails where they are.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(closeDrag)
        #endif
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 620)
        #endif
    }

    private func content(for entry: KidPlayerModel.Entry) -> some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 0)

            cover(for: entry.item)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Text(entry.item.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                artist(for: entry.item)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)

            PlaybackScrubber(player: player)
                .padding(.horizontal, 32)
                .padding(.top, 24)

            if let message = player.message {
                // The one block a kid is ever shown, in the same plain words the
                // bar uses. No error code, no mention of the rule.
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
            }

            controls(for: entry)
                .padding(.top, 24)
                .padding(.bottom, 40)
        }
        // Keyed to the song, so skipping replaces the lineage rather than
        // leaving the last track's record under a new title — and to whether
        // this is on screen at all, because the player outlives its own
        // closing and a resolve for every track a kid skips past is a request
        // for a link nobody can see.
        .task(id: isShowing ? entry.item.id : nil) {
            guard isShowing else { return }
            await lineage.load(entry.item, from: session)
        }
    }

    /// The cover, and the way to the record it is a cover of.
    ///
    /// Tappable only when there is somewhere to go. The alternative — always
    /// tappable, doing nothing when the album is denied — is a picture that
    /// answers a finger and then sits there, which is how a kid learns the app
    /// is broken rather than that a rule exists.
    ///
    /// **A tap and not a `Button`.** A button claims the touch the moment it
    /// lands, and the cover is the biggest thing on the screen — so the one
    /// place a kid would naturally put a finger to drag the player away was the
    /// one place the drag could not start. A tap gesture gives way as soon as
    /// the finger moves, which is exactly the difference between the two
    /// meanings of touching a picture.
    @ViewBuilder
    private func cover(for song: CatalogItem) -> some View {
        if let album = lineage.album {
            artwork(for: song)
                .onTapGesture { open(album) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open the album \(album.title)")
        } else {
            artwork(for: song)
                .accessibilityHidden(true)
        }
    }

    private func artwork(for song: CatalogItem) -> some View {
        ArtworkImage(url: song.artworkURL) { image in
            image.resizable()
        } placeholder: {
            RoundedRectangle(cornerRadius: 16).fill(.quaternary)
        }
        .aspectRatio(1, contentMode: .fit)
        // Clipping yes, compositing never: nothing is ever drawn on top of
        // Apple's artwork, which is why the heart lives in the row below and not
        // in a corner of the picture — and why tapping the cover has no glyph on
        // it saying so.
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 420)
        .padding(.horizontal, 32)
        .shadow(radius: 12, y: 6)
    }

    /// Who made it, as a chip when the kid may open them and as plain text when
    /// they may not.
    ///
    /// Plain text is the fallback, not a lesser version of the same thing — the
    /// same call ``AlbumView`` makes about its credits. The name stays either
    /// way, because it is the song's subtitle everywhere else in the app and a
    /// song with no artist under it reads as missing rather than as restricted.
    @ViewBuilder
    private func artist(for song: CatalogItem) -> some View {
        if let artist = lineage.artist {
            // A tap rather than a button, for the reason the cover is one.
            ArtistChip(artist: artist)
                .onTapGesture { open(artist) }
                .accessibilityAddTraits(.isButton)
        } else if let subtitle = song.subtitle {
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
    }

    /// Closes the player, then pushes.
    ///
    /// In that order: the stack underneath is what the kid is being sent to, and
    /// pushing onto a screen still hidden behind a cover means arriving on it by
    /// having the cover taken away rather than by going anywhere.
    private func open(_ container: CatalogItem) {
        close()
        router?.open(container)
    }

    /// How this screen goes away: a position on iOS, a dismissal on the Mac.
    private func close() {
        #if os(iOS)
        expansion?.close()
        #else
        dismiss()
        #endif
    }

    /// One way out, and it is the biggest thing at the top.
    ///
    /// A kid who cannot find the way back out of a screen is stuck in it, and a
    /// swipe is not something to rely on for that — it does not exist on the
    /// Mac at all.
    private var header: some View {
        HStack {
            Button { close() } label: {
                Image(systemName: "chevron.down")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    #if os(iOS)
    /// Dragging the screen down takes it down with the finger, and lets go of it
    /// where the finger does.
    ///
    /// **Additive, never the way out.** The chevron stays exactly where it was
    /// and stays the biggest thing at the top, because a gesture is invisible,
    /// undiscoverable by a child who does not already know it is there, and
    /// absent on the Mac. This is the shortcut for a kid who reaches for it; the
    /// button is the way out for one who does not.
    ///
    /// The movement itself belongs to ``PlayerExpansion``, not to this view: it
    /// is the same drag the bar starts on the way up, and a finger that pulls
    /// the player halfway and pushes it back down never let go in between.
    ///
    /// **Measured against the window, not against this view.** A drag reported
    /// in local space is measured from where the finger started *in the thing
    /// being moved* — so moving the player down by a hundred points takes a
    /// hundred points off the very translation that moved it, which feeds back
    /// on itself and the screen judders and drifts behind the finger under a
    /// spring that never settles. Global space is the same finger and a fixed
    /// origin.
    ///
    /// `.gesture` and not `.simultaneousGesture`: a gesture attached out here
    /// loses to the ones inside it, which is what keeps the scrubber scrubbing
    /// and the buttons pressable instead of sliding the whole screen out from
    /// under a finger that was aiming at the playhead.
    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { expansion?.pull(by: $0.translation.height) }
            .onEnded { expansion?.release(projected: $0.translation.height + $0.velocity.height / 4) }
    }
    #endif

    /// Play, pause and skip at the size the spec asks for, with the two things
    /// that act on the song already playing rather than leading anywhere.
    private func controls(for entry: KidPlayerModel.Entry) -> some View {
        HStack(spacing: 36) {
            HeartButton(session: session, item: entry.item, origin: entry.origin)

            Button {
                Task { await player.togglePlayPause() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .frame(width: 88, height: 88)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                Task { await player.skip() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip")

            AddToPlaylistButton(session: session, item: entry.item, origin: entry.origin)
        }
    }
}

/// The record a song is on and who made it, as far as this kid may reach them.
///
/// **A name is not a permission.** The identifiers come off the song's own
/// ancestry, which says nothing about whether the kid may go there, so both go
/// through ``Session/resolveAllowed(_:)`` before either becomes a link. A denied
/// artist leaves ``artist`` nil and the player draws their name as plain text; a
/// denied album leaves ``album`` nil and the cover is a picture rather than a
/// button. Neither case is an error and neither is shown as one.
///
/// Decoration in the sense ``AlbumView`` uses the word: a lookup that fails
/// leaves the player working, with two fewer places to go.
@MainActor
@Observable
final class Lineage {
    private(set) var album: CatalogItem?
    private(set) var artist: CatalogItem?

    func load(_ song: CatalogItem, from session: Session) async {
        let albumID = song.ancestors.first { $0.id.kind == .album }?.id
        let artistID = song.ancestors.first { $0.id.kind == .artist }?.id
        let ids = [albumID, artistID].compactMap { $0 }

        // Cleared first, not left standing while the next request runs: this is
        // reloaded on a skip, and the moment between two tracks must not be one
        // where the cover opens the previous song's record.
        album = nil
        artist = nil
        guard !ids.isEmpty else { return }

        // One batch for both, because ancestry is resolved in batch and two
        // requests here would be two round trips for a header.
        let resolved = (try? await session.resolveAllowed(ids)) ?? []
        album = resolved.first { $0.id == albumID }
        artist = resolved.first { $0.id == artistID }
    }
}

/// The playhead, and the two numbers either side of it.
///
/// **The drag owns the thumb while it lasts.** ``KidPlayerModel/playbackTime``
/// is refreshed twice a second by the poll that keeps the play button honest,
/// and a slider bound straight to it would yank itself out from under a finger
/// every half second. So a drag in progress is held here and only handed to the
/// player when it ends.
///
/// Absent entirely when the catalog gave no duration. A scrubber with a guessed
/// end is a control that lies about where the song finishes, and the elapsed
/// time alone is honest.
struct PlaybackScrubber: View {
    @Bindable var player: KidPlayerModel

    @State private var dragging: TimeInterval?

    var body: some View {
        if let duration = player.duration {
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { min(position, duration) },
                        set: { dragging = $0 }
                    ),
                    in: 0...duration,
                    onEditingChanged: { isEditing in
                        guard !isEditing, let target = dragging else { return }
                        // Cleared after the seek, not before: the seek sets
                        // `playbackTime` itself, so the thumb never falls back
                        // to where it was for the half second until the next
                        // poll.
                        Task {
                            await player.seek(to: target)
                            dragging = nil
                        }
                    }
                )
                .accessibilityLabel("Playback position")
                .accessibilityValue(Self.clock(position))

                HStack {
                    Text(Self.clock(position))
                    Spacer()
                    Text("-" + Self.clock(max(0, duration - position)))
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        } else {
            Text(Self.clock(position))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var position: TimeInterval {
        dragging ?? player.playbackTime
    }

    /// `m:ss`, the way a song's length is written everywhere else.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
