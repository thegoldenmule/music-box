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

    /// Where a tapped invitation link is waiting, if there is one.
    ///
    /// Watched here rather than on the sharing screen because a link can be
    /// tapped when that screen has never been opened — which is the ordinary case
    /// for the second parent, whose first contact with this app *is* the link.
    private let shares = ShareAcceptance.shared

    @Environment(\.scenePhase) private var scenePhase

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
                    bound
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
        .task {
            await session.start()

            // **Before the binding, and the order is load-bearing.** A link
            // tapped on a cold launch is already in the inbox by the time this
            // runs, and accepting changes which database this device writes to.
            // `resolveBinding` writes — it stamps this device's row — so it
            // spawns a push, and a push before the acceptance addresses the
            // private zones nobody else can see. Joining first means there is no
            // such window to reason about. Acceptance needs nothing the binding
            // provides, which is what makes this free.
            await session.acceptPendingShares()

            // After `start`, because it needs the roster loaded to tell a bound
            // child from a missing one — and before anything draws a player,
            // because which child that is, is what this decides.
            await session.resolveBinding()

            await session.syncPass()
        }
        // **A link can arrive while the app is already running**, straight from
        // Messages, with no phase change of its own on a Mac and only a brief one
        // on iOS. Watching the inbox rather than the phase is what catches both.
        .onChange(of: shares.waiting.count) { _, count in
            guard count > 0 else { return }
            Task { await session.acceptPendingShares() }
        }
        // Coming back is when a co-parent's edits are most likely to be waiting,
        // and when this device's own are most likely to be owed. Nothing fires on
        // the way in — `onChange` skips the initial value — so this does not
        // double up with the `task` above.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await session.syncPass() }
        }
    }

    /// Which child this device opens into — or why it does not.
    ///
    /// **The lock cases draw a dead end on purpose.** `BindingResolver`'s rule
    /// is that a mismatch never falls back to another kid, so this switch must
    /// not acquire a "pick someone" escape hatch; that is what would turn a
    /// hand-me-down iPad into a sibling's sandbox.
    @ViewBuilder private var bound: some View {
        switch session.binding {
        case .open, .parentOnly:
            // `parentOnly` still lands here for now: the admin surface is inside
            // the kid screen's gate, and giving a grown-up's phone its own root
            // is a separate piece of work. Naming the case rather than folding
            // it into a default is what will make that obvious when it happens.
            KidHomeView(session: session)

        case .unenrolled:
            DeviceSetupView(session: session)

        // **Three locks that setup can fix, and it must be allowed to.** Each of
        // these is an incomplete setup rather than a refusal: nobody has said
        // whose device this is, or there is no passcode, or the child it points
        // at has left the family. A dead end here would brick the only device a
        // family owns, with the instructions on it describing a screen they
        // cannot reach — the admin surface lives behind the kid's player, which
        // is the thing being withheld.
        //
        // It gives nothing away. Setup opens no player, and `Enrollment` will
        // not bind a child without a passcode, so the way out is gated by the
        // same code the lock is protecting.
        case .locked(.notBound), .locked(.noGate), .locked(.boundKidMissing):
            DeviceSetupView(session: session)

        // And the two that are refusals. A revoked device and a device under an
        // account it was not set up with are the cases where somebody has
        // decided something, or something has happened nobody told us about —
        // see `BindingResolver`. Neither may be argued with from the device.
        case .locked(let reason):
            DeviceLockedView(reason: reason, kids: session.kids)
        }
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
