import CatalogKit
import SwiftUI

/// The gate: nothing is worth showing until Apple Music has authorized us.
///
/// Both questions — authorization, then a subscription that can actually play
/// catalog content — are still asked before a kid taps anything, and asking
/// them up front rather than at play time is still deliberate: finding out at
/// the moment a kid presses play that the account cannot play it is the worst
/// possible time to find out.
///
/// What changed is that only the first of the two is *waited on*. The
/// subscription answer lands behind this screen and swaps it out if it is bad;
/// it no longer holds a blank window open for however long Apple takes to
/// reply. See ``Session/start()``.
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
                // The shared-device question goes here, between authorization
                // and the kid's first screen. That position is the whole of its
                // safety story: the answer has to be in before anything can be
                // read from the Apple Music library, and this is the last point
                // where nothing has been.
                if session.hasAnsweredSharedDevice {
                    KidHomeView(session: session)
                } else {
                    SharedDeviceOnboardingView(session: session)
                }
            }
        }
        // **The one place Reduce Motion is read.** Everything below asks
        // `\.motion` for an animation and gets the right answer without knowing
        // the setting exists — see ``Motion``. Outside this modifier the palette
        // defaults to motion-on, which is the safe way round: a view drawn
        // somewhere unexpected animates normally rather than silently behaving as
        // though the accessibility setting were turned on.
        .resolvingMotion()
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
