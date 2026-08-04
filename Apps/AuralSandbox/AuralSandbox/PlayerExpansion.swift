#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// Where the full-screen player is between the bar and the top of the screen.
///
/// One number, written by two views. The bar starts the pull upward and
/// ``NowPlayingView`` finishes it, and either can be reversed by the same finger
/// without ever letting go — which is the whole reason this type exists. A
/// `fullScreenCover` is a switch, and a switch cannot be half way. The player is
/// an overlay on ``KidHomeView`` so that it can be somewhere in between, and
/// stay there for as long as a finger is on it.
///
/// The Mac has none of this. There is no finger there, a sheet *is* what "the
/// whole window" means, and ``NowPlayingBar`` still presents one.
///
/// **The way out is still the chevron.** This adds a second way, one a kid may
/// never find on their own and does not have to: everything a drag can do, a tap
/// already did.
@MainActor
@Observable
final class PlayerExpansion {
    /// Where it is meant to come to rest: all the way up, or off the bottom.
    private(set) var isOpen = false

    /// What the finger is adding right now, in points. Zero at rest, whichever
    /// rest it is at.
    private(set) var drag: CGFloat = 0

    /// How far down the screen the player is drawn. Zero is open; a screen's
    /// height is off the bottom.
    ///
    /// Clamped at the top: an over-pull past open goes nowhere, because there is
    /// nothing above the player and a screen that keeps travelling upward leaves
    /// a band of nothing under it.
    var offset: CGFloat {
        max(0, isOpen ? drag : screenHeight + drag)
    }

    /// Whether any of it can be seen. The player is in the hierarchy at all
    /// times, so this is what stands in for "on screen" — it gates the work that
    /// would otherwise be done for a screen nobody is looking at.
    var isShowing: Bool { isOpen || drag != 0 }

    /// Slow enough to be seen leaving, quick enough not to be waited on, and
    /// barely bouncy — this is a screen a kid opens and closes dozens of times
    /// an hour. Now ``Motion/settle``, which is the same curve named.
    ///
    /// **The palette is a parameter rather than an environment read, because this
    /// is a model and not a view.** That is the one place the motion vocabulary
    /// cannot reach on its own, and passing it makes the dependency visible
    /// instead of leaving Reduce Motion quietly unhonoured on the one screen in
    /// the app a finger drags.

    /// Far enough that a finger resting still has not asked for anything, near
    /// enough that a flick lands. Distance *plus* projected velocity is measured
    /// against it, so both a slow haul and a fast flick can reach it.
    private static let threshold: CGFloat = 140

    func open(_ motion: MotionPalette = MotionPalette()) {
        withAnimation(motion.settle) {
            isOpen = true
            drag = 0
        }
    }

    func close(_ motion: MotionPalette = MotionPalette()) {
        withAnimation(motion.settle) {
            isOpen = false
            drag = 0
        }
    }

    /// A finger has moved, from whichever of the two views the drag began in.
    ///
    /// **Nothing happens under Reduce Motion, and that is the whole of it.** With
    /// the setting on ``ExpandedPlayer`` pins the player in place and cross-fades
    /// instead, so a drag has nothing to move — and a gesture that visibly does
    /// nothing is worse than one that politely declines. The tap is untouched,
    /// and this file has said from the start that the tap is the way this is
    /// meant to be found: "everything a drag can do, a tap already did".
    ///
    /// The guard lives here rather than at the two gesture sites so there is one
    /// rule instead of four closures that have to remember it.
    func pull(by translation: CGFloat, motion: MotionPalette = MotionPalette()) {
        guard !motion.reduceMotion else { return }
        if isOpen {
            // Downward is followed point for point; upward is resisted rather
            // than refused, so a finger that wanders gets an answer without the
            // screen lifting off the top of the window.
            drag = translation > 0 ? translation : translation / 6
        } else {
            // Nothing lives below the bar, so downward on it does nothing at
            // all.
            drag = min(0, translation)
        }
    }

    /// The finger has let go. `projected` is where it was heading, not where it
    /// stopped — a kid's flick is fast and travels barely any distance, and
    /// judging on distance alone refuses it.
    ///
    /// **A flick and a slow haul settle with the same animation, deliberately.**
    /// SwiftUI tracks the gesture's velocity and hands it to the spring, so the
    /// difference between the two arrives as initial velocity rather than as a
    /// second constant — and a second constant here would double-count what the
    /// gesture already said. See ``Motion``.
    func release(projected: CGFloat, motion: MotionPalette = MotionPalette()) {
        // Nothing was pulled, so there is nothing to settle — see ``pull(by:motion:)``.
        guard !motion.reduceMotion else { return }
        if isOpen {
            if projected > Self.threshold {
                close(motion)
            } else {
                withAnimation(motion.settle) { drag = 0 }
            }
        } else if projected < -Self.threshold {
            open(motion)
        } else {
            withAnimation(motion.settle) { drag = 0 }
        }
    }

    // MARK: - What the window knows and SwiftUI here does not

    /// The window's own height and insets.
    ///
    /// **Asked of UIKit because nothing in this position has them to give.** The
    /// player is drawn over a `NavigationStack` that has already taken the safe
    /// area for itself, so an overlay on it inherits a safe area of nothing —
    /// which is how the close button ended up under the clock, and why a
    /// `GeometryReader` there reports zero insets and cannot be asked instead.
    ///
    /// Read rather than stored, so a rotation cannot leave a stale number
    /// holding the player a hundred points off the bottom of the screen.
    private var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    /// How far off the bottom "closed" is: the whole window, not the part of it
    /// left over after the bars. A screen's worth short and the top edge of the
    /// player sits visible above the home indicator.
    var screenHeight: CGFloat { window?.bounds.height ?? 900 }

    /// Where it is safe to put words and controls, given the player draws under
    /// the status bar and the home indicator rather than behind them.
    var safeAreaInsets: EdgeInsets {
        guard let insets = window?.safeAreaInsets else { return EdgeInsets() }
        return EdgeInsets(
            top: insets.top,
            leading: insets.left,
            bottom: insets.bottom,
            trailing: insets.right
        )
    }
}

/// The full-screen player, as something that can be half-way up.
///
/// An overlay on the kid's whole stack rather than a modal, so that a drag can
/// move it and let go of it again. Everything else about ``NowPlayingView`` is
/// unchanged, including that it sits outside the `NavigationStack` and reaches
/// it through ``KidRouter`` — an overlay over the stack is no more inside it
/// than a cover over it was.
///
/// **It is never inserted and never removed.** Position is the only thing that
/// changes, which is what makes the movement one continuous thing a finger can
/// turn around half way through. A view that arrives as it starts moving
/// arrives *visibly*: the cover came up already drawn and then slid, because
/// laying it out and animating it were two different moments. Nothing here is
/// laid out at the moment it is asked to move.
///
/// The cost is a player that exists while it is closed, which is why
/// ``PlayerExpansion/isShowing`` is handed down — see ``NowPlayingView`` and
/// what it does not go and fetch for a screen nobody can see.
struct ExpandedPlayer: View {
    @Bindable var session: Session
    @Bindable var player: KidPlayerModel
    let expansion: PlayerExpansion

    /// **Reduce Motion replaces the travel, not just the curve.**
    ///
    /// Swapping the spring for a gentler one is what the rest of the app does and
    /// it is not enough here: HIG Accessibility asks for "replacing transitions in
    /// x-, y-, and z-axes with fades to avoid motion", and a screen-sized surface
    /// flying up from the bottom is the largest piece of x/y travel in the app. So
    /// with the setting on it does not travel at all — it is already in place and
    /// only its opacity changes.
    ///
    /// Read here rather than taken from ``MotionPalette`` because this is a
    /// question about *what is drawn*, not about which animation to use, and
    /// because it has to be answered on every layout rather than at the moment
    /// something was opened — a parent can turn the setting on while the player
    /// is up.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NowPlayingView(session: session, player: player, isShowing: expansion.isShowing)
            // The safe area, put back by hand. `ignoresSafeArea` first so the
            // frame is the whole window whatever this position inherits, and
            // then the window's own insets as padding — the background bleeds
            // to the edges of the screen and the words never do.
            .padding(.top, expansion.safeAreaInsets.top)
            .padding(.bottom, expansion.safeAreaInsets.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Rectangle().fill(.background))
            .ignoresSafeArea()
            // Pinned in place under Reduce Motion. `offset` still computes the
            // travel and is simply not asked for, so nothing about the drag model
            // changes shape — see ``PlayerExpansion/offset``.
            .offset(y: reduceMotion ? 0 : expansion.offset)
            // The cross-fade. Driven by `isOpen`, which changes inside the
            // `withAnimation` in ``PlayerExpansion/open(_:)`` — and that animation
            // is already ``Motion/reduced`` when the setting is on, so the fade
            // gets the right curve without asking for it twice.
            .opacity(reduceMotion && !expansion.isOpen ? 0 : 1)
            // Closed, this is a screen-sized opaque thing sitting just off the
            // bottom. Off-screen views take no touches, but the flag says so
            // out loud, and it is what keeps the bar's own drag alive while the
            // player is being pulled up over the top of it: a hit region that
            // appeared under a finger mid-drag would take the gesture away from
            // the view that started it.
            .allowsHitTesting(expansion.isOpen)
            // **Necessary because of the line above it.** Closed with Reduce
            // Motion on, this is no longer parked off the bottom of the screen —
            // it is lying invisible directly over the home screen, and an
            // `opacity(0)` view is still in the accessibility tree. Without this
            // VoiceOver would read the whole player over the top of the shelves,
            // which is a worse bug than the one being fixed. True in both modes,
            // so it is stated unconditionally: closed is closed.
            .accessibilityHidden(!expansion.isOpen)
    }
}
#endif
