import KidLibrary
import SwiftUI

/// Two questions, asked before anything is read.
///
/// The thing the app needs to know is *"is the Apple Music library on this
/// device the kid's own?"* — which is not a question a parent can answer without
/// first working out what it means. These two they already know the answer to,
/// and between them they decide it. See ``DeviceLibraryState/isSharedDevice``.
///
/// The second question is why there are two. A hand-me-down phone nobody else
/// touches is not a shared device and is still not the kid's library, and asking
/// only the first gets that case exactly backwards.
///
/// It is also the second question **only**, and disabled when the first is yes.
/// On a device a grown-up shares, the account signed in is the grown-up's and
/// the library is theirs whatever else is true of the family — the derivation
/// gives the same answer either way, so leaving it live would invite a parent to
/// answer something that cannot change the outcome.
///
/// **Why here rather than in the admin alone.** The first read of the Apple
/// Music library is the one moment this feature can go badly wrong: the pass
/// that gives a kid with their own account their own music is the same pass that
/// would pull an adult library onto a child's shelf. Asking before that read is
/// what makes the default safe.
struct SharedDeviceOnboardingView: View {
    @Bindable var session: Session

    /// Started at the answers that keep the Apple Music library out of it.
    ///
    /// The stored default is the other way — both providers live — because that
    /// one only ever governs "the questions were somehow never put". These
    /// govern "a parent tapped Continue without reading", which wants the
    /// conservative answer.
    @State private var sharesDevice = true
    @State private var childHasOwnAccount = false

    private var isKidsOwnLibrary: Bool { !sharesDevice && childHasOwnAccount }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Setup")
                .font(.largeTitle.bold())

            VStack(spacing: 16) {
                Toggle("Are you sharing this device with your child?", isOn: $sharesDevice)
                Divider()
                Toggle(
                    "Does your child have an Apple Music account of their own, through your Apple Family?",
                    isOn: $childHasOwnAccount
                )
                // Moot on a shared device: the account signed in is a grown-up's
                // and the library is theirs whichever way this points.
                .disabled(sharesDevice)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary))

            // What the answers add up to, in one line, before Continue is
            // pressed rather than discovered afterwards.
            Text(outcome)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                session.setDeviceAnswers(
                    sharesDevice: sharesDevice,
                    childHasOwnAccount: childHasOwnAccount
                )
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("You can change this whenever you like, in the admin.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: 480)
        .padding(24)
    }

    /// One sentence per outcome, plus the disclosure where it applies.
    ///
    /// §3.3.6(D) permits user metadata for a function "clearly disclosed to end
    /// users" — a condition, not a description. This app has kept a child's
    /// listening entirely local until now, so the sentence goes here rather than
    /// being discovered later. It appears only in the case where it is true.
    private var outcome: String {
        isKidsOwnLibrary
            ? "Their favorites and playlists will live in your child's Apple Music library too, and whatever is already in it shows up here. What they keep is sent to Apple under your family's account and nowhere else."
            : "Their favorites and playlists will live in this app only. Nothing is read from the Apple Music library on this device, and nothing is written to it."
    }
}
