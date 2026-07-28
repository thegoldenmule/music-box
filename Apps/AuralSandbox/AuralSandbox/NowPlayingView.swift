import CatalogKit
import FamilyStore
import SwiftUI

/// The now playing bar, opened up.
///
/// Same song, same controls, and **nothing the bar does not already offer** — a
/// bigger picture, the words at a size a kid can read across a room, and one
/// addition: the scrubber. It is the fourth control, and it earns its place by
/// passing the test the other three pass: it is not a door. Dragging the
/// playhead reaches nowhere the verdict that started this track did not already
/// allow, unlike a next-up list, a "go to artist", or a station.
///
/// It deliberately has no queue, no lyrics, no "more like this" and no share.
/// The whole promise of this app is that a screen a child is left alone with
/// leads nowhere, and the full-screen player is the screen they will be left
/// alone with the longest.
struct NowPlayingView: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let entry = player.current {
                content(for: entry)
            } else {
                // The queue ran out while this was open. Nothing to show, and a
                // kid staring at a blank screen with no way back is worse than
                // being returned to what they were doing.
                Color.clear.onAppear { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 620)
        #endif
    }

    private func content(for entry: KidPlayerModel.Entry) -> some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 0)

            AsyncImage(url: entry.item.artworkURL) { image in
                image.resizable()
            } placeholder: {
                RoundedRectangle(cornerRadius: 16).fill(.quaternary)
            }
            .aspectRatio(1, contentMode: .fit)
            // Clipping yes, compositing never: nothing is ever drawn on top of
            // Apple's artwork, which is why the heart lives in the row below and
            // not in a corner of the picture.
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
            .shadow(radius: 12, y: 6)

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Text(entry.item.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let subtitle = entry.item.subtitle {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
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
    }

    /// One way out, and it is the biggest thing at the top.
    ///
    /// A kid who cannot find the way back out of a screen is stuck in it, and a
    /// swipe is not something to rely on for that — it does not exist on the
    /// Mac at all.
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
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
