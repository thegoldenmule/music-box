import CatalogKit
import SwiftUI

/// What is playing, and the only three controls there are.
///
/// Play, pause, skip. No scrubber, no shuffle, no repeat, no next-up list, no
/// "go to artist" — every one of those is a door, and this app's whole promise
/// is that there are none.
///
/// Skip stops at the end of the queue rather than finding something else to
/// play. Autoplay past the end is the fourth MusicKit affordance this app never
/// uses, and the queue living in ``KidPlayerModel`` is what makes that true by
/// construction rather than by remembering to switch it off.
struct NowPlayingBar: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel

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
                    AsyncImage(url: entry.item.artworkURL) { image in
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

                    Button {
                        Task { await player.togglePlayPause() }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        Task { await player.skip() }
                    } label: {
                        Image(systemName: "forward.fill").font(.title2)
                    }
                    .accessibilityLabel("Skip")
                }
                .buttonStyle(.plain)
                .padding()
            }
            .background(.bar)
        }
    }
}
