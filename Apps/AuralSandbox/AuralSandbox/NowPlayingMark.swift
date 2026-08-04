import SwiftUI

/// The mark that says *this is the one you are hearing*.
///
/// **What it is for.** ``NowPlayingBar`` says what is playing; it does not say
/// which of the twelve nearly identical rows in front of the kid that is. On an
/// album screen those two facts were never connected, so a child looking at a
/// track list had to read the titles and match them — which is exactly the thing
/// this app cannot ask of the person using it.
///
/// **Deliberately the same figure as ``SearchingView``.** Bars that bounce mean
/// "the app is doing something with sound" in both places, and a kid meets it on
/// the searching screen long before they meet it in a list. Smaller here, and
/// three bars rather than five, because it sits in the slot a track number or a
/// play triangle occupies.
///
/// **Still, not stopped, when paused.** Frozen bars are the difference between
/// "this is the song" and "this song is playing", and both are worth saying: a
/// kid who pauses still wants to see where they were. This is the Music app's own
/// behaviour and it costs one flag.
struct NowPlayingMark: View {
    /// Whether the sound is actually coming out. False leaves the bars standing
    /// at their resting heights, which still marks the row.
    var isAnimating: Bool

    /// The one accessibility signal that matters here is not this view's — see
    /// the `accessibilityValue` on the rows that draw it. Bars are decoration and
    /// VoiceOver landing on three of them says nothing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bouncing = false

    /// Where each bar stands when nothing is moving — an equalizer paused, not
    /// three identical sticks. Uneven on purpose, the way ``SearchingView``'s are.
    private static let resting: [CGFloat] = [0.55, 1.0, 0.75]

    private static let barWidth: CGFloat = 3
    private static let height: CGFloat = 14

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(Self.resting.enumerated()), id: \.offset) { index, resting in
                Capsule()
                    .fill(.tint)
                    .frame(width: Self.barWidth, height: Self.height)
                    .scaleEffect(y: scale(index: index, resting: resting), anchor: .bottom)
                    .animation(animation(index: index), value: bouncing)
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .onAppear { bouncing = true }
        .accessibilityHidden(true)
    }

    private func scale(index: Int, resting: CGFloat) -> CGFloat {
        // Paused or Reduce Motion: stand still at the resting height. The row is
        // still marked, which is the part that carries the meaning.
        guard isAnimating, !reduceMotion else { return resting }
        return bouncing ? 1 : 0.35
    }

    /// `nil` under Reduce Motion or when paused — and `nil` is what actually
    /// stops it. A `repeatForever` attached to a value that never changes again
    /// keeps running however gentle the curve, which is the rule
    /// ``SearchingView`` records and the reason this returns an optional rather
    /// than a slower animation.
    private func animation(index: Int) -> Animation? {
        guard isAnimating, !reduceMotion else { return nil }
        return .easeInOut(duration: 0.42)
            .repeatForever(autoreverses: true)
            // Offset per bar so the three are never in step, which is what makes
            // it read as sound rather than as a progress indicator.
            .delay(Double(index) * 0.14)
    }
}
