import CatalogKit
import SwiftUI

/// The gate: nothing is worth showing until Apple Music says yes twice —
/// authorization, then a subscription that can actually play catalog content.
///
/// Asking both up front rather than at play time is deliberate. Finding out at
/// the moment a kid taps a song that the account cannot play it is the worst
/// possible time to find out.
struct RootView: View {
    @Bindable var session: Session

    var body: some View {
        Group {
            switch session.access {
            case .checking:
                ProgressView("Checking Apple Music…")

            case .needsAuthorization(let status):
                ContentUnavailableView {
                    Label("Apple Music access needed", systemImage: "music.note")
                } description: {
                    Text(explanation(for: status))
                }

            case .cannotPlay(let subscription):
                ContentUnavailableView {
                    Label("Nothing will play", systemImage: "exclamationmark.triangle")
                } description: {
                    // canBecomeSubscriber is deliberately not acted on here.
                    // Nothing about buying anything belongs on a kid's screen.
                    Text(
                        subscription.canBecomeSubscriber
                            ? "This account has no active Apple Music subscription."
                            : "This account can't play Apple Music catalog content."
                    )
                }

            case .ready:
                KidHomeView(session: session)

            case .failed(let message):
                ContentUnavailableView {
                    Label("Apple Music isn't answering", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                }
            }
        }
        .task { await session.start() }
    }

    private func explanation(for status: AuthorizationStatus) -> String {
        switch status {
        case .denied:
            "Access was denied. Turn it back on in Settings → Privacy → Media & Apple Music."
        case .restricted:
            // Screen Time or a device management profile — outside this app, and
            // the app has to keep working and say so rather than pretending.
            "Something outside this app is restricting Apple Music — check Screen Time."
        case .notDetermined:
            "Aural Sandbox needs permission to use Apple Music."
        case .authorized:
            ""
        }
    }
}
