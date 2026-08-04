import SwiftUI

/// How this app moves, in one place.
///
/// **Springs, not easing, and that is Apple's default rather than a preference.**
/// From WWDC23 *Animate with springs*: "we now use them as the default animation
/// in SwiftUI, so all you need to do is call `withAnimation`". Every
/// `easeInOut(duration:)` is an active decision to override that with something
/// worse.
///
/// The mechanism, from *Explore SwiftUI animation*, is `shouldMerge`: spring
/// animations return true and take on the in-flight animation's velocity, so a
/// second change retargets rather than running a second curve additively. Timing
/// curves return false. That is the whole of what "interruptible" means, and it
/// is why a kid tapping the same thing twice in 200ms gets one movement from a
/// spring and a fight from an ease.
///
/// **Easing survives in exactly two places**: a pure opacity cross-fade, where
/// nothing travels so there is no velocity to preserve and nothing to overshoot;
/// and the Reduce Motion substitute.
///
/// **Availability**: every preset here is back-deployed far below this project's
/// floor. `SwiftUICore.swiftinterface:13073` opens the extension with
/// `@available(iOS 13.0, macOS 10.15, …)` and each member is
/// `@_alwaysEmitIntoClient`, bottoming out in the iOS 13
/// `spring(response:dampingFraction:)`. Bounce values are from that source:
/// smooth `0.0`, snappy `0.15`, bouncy `0.3`. No `#available` is needed.
///
/// Nothing here knows about Reduce Motion — see ``MotionPalette``, which is the
/// only place that decision is made.
enum Motion {
    /// A finger is still down. Highest blend, shortest life, so a press that
    /// changes its mind can be taken back mid-gesture.
    static let interactive = Animation.interactiveSpring(duration: 0.2)

    /// The default for any change the kid caused.
    static let standard = Animation.snappy(duration: 0.3)

    /// A screen-sized surface arriving or leaving. Longer than a tile because it
    /// travels further; barely bouncy because a kid opens it dozens of times an
    /// hour. `extraBounce: -0.03` against snappy's 0.15 is the 0.12 the player
    /// was already tuned to.
    static let settle = Animation.snappy(duration: 0.42, extraBounce: -0.03)

    /// Long spatial travel — a scroll returning to the top. Bounce nets to zero:
    /// overshoot past a scroll boundary reads as a rubber-band that never
    /// happened.
    static let travel = Animation.snappy(duration: 0.45, extraBounce: -0.15)

    /// Reward. The one place overshoot *is* the content: a kid keeping something
    /// is the only tap in the app that means *mine*.
    static let playful = Animation.bouncy(duration: 0.4, extraBounce: 0.05)

    /// Content replacing content in place. Nothing travels, so no spring — and a
    /// short tail, because a fast search turns a long one into a flash.
    static let fade = Animation.easeOut(duration: 0.18)

    /// Something the kid did not ask for — a shelf reloading under them. Slow and
    /// flat: bounce would claim credit for a change nobody initiated.
    static let ambient = Animation.smooth(duration: 0.5)

    /// The skeleton's two-state opacity loop.
    static let pulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    /// One equalizer bar. Shared by ``SearchingView`` and ``NowPlayingMark`` so
    /// the two figures that both mean "sound" move at the same rate.
    static let bars = Animation.easeInOut(duration: 0.42).repeatForever(autoreverses: true)

    /// **A cross-fade, not an absence.** HIG Accessibility asks for "replacing
    /// transitions in x-, y-, and z-axes with fades to avoid motion" and
    /// "tightening animation springs to reduce bounce effects" — so the
    /// substitute still animates, it just does not travel or overshoot.
    static let reduced = Animation.easeInOut(duration: 0.2)
}

/// ``Motion``, resolved against Reduce Motion.
///
/// The reason this type exists rather than call sites reading the environment
/// themselves: Reduce Motion is an environment value and a `static let` cannot
/// read one, so the vocabulary and the substitution cannot live in the same
/// place. Every view asks the palette; **only the palette asks the system.**
struct MotionPalette: Sendable {
    var reduceMotion = false

    private func resolve(_ animation: Animation) -> Animation {
        reduceMotion ? Motion.reduced : animation
    }

    var interactive: Animation { resolve(Motion.interactive) }
    var standard: Animation { resolve(Motion.standard) }
    var settle: Animation { resolve(Motion.settle) }
    var travel: Animation { resolve(Motion.travel) }
    var playful: Animation { resolve(Motion.playful) }
    var fade: Animation { resolve(Motion.fade) }
    var ambient: Animation { resolve(Motion.ambient) }

    /// `nil` under Reduce Motion, and `nil` is what actually stops it — a
    /// `repeatForever` attached to a value that never changes again keeps running
    /// however gentle the curve is. The two repeating animations are the only
    /// members that return an optional, and that asymmetry is the point rather
    /// than an oversight.
    var pulse: Animation? { reduceMotion ? nil : Motion.pulse }
    var bars: Animation? { reduceMotion ? nil : Motion.bars }
}

private struct MotionPaletteKey: EnvironmentKey {
    /// Motion on, which is what an unresolved environment should mean: a view
    /// drawn outside ``View/resolvingMotion()`` animates normally rather than
    /// silently behaving as though the accessibility setting were on.
    static let defaultValue = MotionPalette()
}

extension EnvironmentValues {
    var motion: MotionPalette {
        get { self[MotionPaletteKey.self] }
        set { self[MotionPaletteKey.self] = newValue }
    }
}

private struct MotionResolver: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.environment(\.motion, MotionPalette(reduceMotion: reduceMotion))
    }
}

extension View {
    /// Applied once, at the root. Everything below reads `\.motion` and is
    /// already correct — which is the whole point: Reduce Motion is honoured in
    /// one place instead of being remembered at thirty call sites.
    func resolvingMotion() -> some View { modifier(MotionResolver()) }
}

/// A tap target that answers the finger.
///
/// `.buttonStyle(.plain)` gives **no** pressed state at all, and the kid side
/// used it on every tile, row and shelf header — so the largest, most-tapped
/// controls in the app were the ones that never acknowledged a touch.
///
/// Scale rather than opacity: a tile is mostly album art, and dimming Apple's
/// artwork is closer to compositing on it than shrinking the frame it sits in.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.motion) private var motion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(motion.interactive, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Reads at the call site exactly where `.plain` used to, which is the point
    /// — the migration is one word per site.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
