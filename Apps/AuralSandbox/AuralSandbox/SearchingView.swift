import SwiftUI

/// What a kid looks at between hitting enter and results arriving.
///
/// A whole screen rather than a spinner laid over the home grid. The old screen
/// staying put reads as "enter did nothing", and a kid's next move is to hit it
/// again — so the search page arrives on the keystroke and only its contents are
/// still on the way.
///
/// Bouncing bars rather than `ProgressView`, for the same reason the rest of the
/// kid side is tiles and not rows: a hairline system spinner is nearly invisible
/// at arm's length on a phone a kid is holding, and this screen's only job is to
/// be seen.
struct SearchingView: View {
    let term: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bouncing = false

    /// Where each bar sits when it is not moving — an equalizer paused, not five
    /// identical stubs. This is what Reduce Motion gets, so it has to look like a
    /// deliberate picture on its own.
    private let restingScale: [CGFloat] = [0.45, 0.8, 1.0, 0.6, 0.9]

    private let barHeight: CGFloat = 84

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            bars
            Text("Looking for “\(term)”")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One announcement for the screen. Five animating bars would otherwise be
        // five elements VoiceOver can land on and none of them says anything.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Looking for \(term)"))
        .onAppear { bouncing = true }
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(Array(restingScale.enumerated()), id: \.offset) { index, resting in
                Capsule()
                    .fill(.tint)
                    .frame(width: 18, height: barHeight)
                    .scaleEffect(y: scale(index: index, resting: resting), anchor: .bottom)
                    .animation(animation(index: index), value: bouncing)
            }
        }
        .frame(height: barHeight, alignment: .bottom)
    }

    private func scale(index: Int, resting: CGFloat) -> CGFloat {
        guard !reduceMotion else { return resting }
        return bouncing ? 1 : 0.3
    }

    /// `nil` under Reduce Motion, which is what actually stops the loop — a
    /// repeating animation attached to a value that never changes again still
    /// runs forever.
    private func animation(index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 0.42)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * 0.09)
    }
}

#Preview {
    SearchingView(term: "taylor swift")
}
