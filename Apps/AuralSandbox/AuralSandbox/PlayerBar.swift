import CatalogKit
import SwiftUI

/// What is playing, and the one control that stops it.
///
/// No next, no previous, no shuffle, and nothing that could reach past the end
/// of what was asked for. Autoplay and radio are two of the four MusicKit
/// affordances this app never uses, because both reach unvetted material.
struct PlayerBar: View {
    @Bindable var session: Session

    var body: some View {
        if let item = session.player.nowPlaying {
            HStack {
                VStack(alignment: .leading) {
                    Text(item.title).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    // Stopping is what writes the play event: duration is the
                    // signal, and it is not known until now.
                    Task { await session.stop() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(.bar)
        }
    }
}
