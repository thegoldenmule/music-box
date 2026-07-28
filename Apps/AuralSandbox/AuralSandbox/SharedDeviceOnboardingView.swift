import KidLibrary
import SwiftUI

/// The one question onboarding has to put before anything is read.
///
/// **Not "do several people use this iPad".** The question is *is the Apple
/// Music library on this device this kid's own?*, and the two come apart in the
/// case the narrower wording misses: a hand-me-down phone only the kid uses,
/// still signed in to a parent's Apple Account. One user, one device, someone
/// else's library.
///
/// It is a question and not a detection on purpose. The app could fingerprint
/// the signed-in iCloud account, but that identifies *which* account and never
/// *whose* — and the iCloud account is not necessarily the one library writes
/// reach. A parent knows the answer with certainty and can be asked once.
/// Anything inferred would be a guess wearing the costume of a fact.
///
/// **Why it is here rather than in the admin alone.** The first read of the
/// Apple Music library is the one moment this feature can go badly wrong: the
/// same pass that gives a kid with their own account their own music would pull
/// an adult library onto a child's shelf. Asking before that read is what makes
/// "both providers" safe as a default rather than merely convenient — a default
/// that had to survive being wrong for weeks would have to be the other one.
struct SharedDeviceOnboardingView: View {
    @Bindable var session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("One question first")
                        .font(.largeTitle.bold())
                    Text("Whose Apple Music library is on this device?")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                // Consequence stated both ways, in plain words, before either is
                // chosen. Neither answer is framed as the right one.
                choice(
                    title: "It's my kid's own",
                    detail: """
                        Their favorites and playlists become real Apple Music \
                        library items that follow them to their account — and \
                        whatever is already in that library becomes theirs here.
                        """,
                    isShared: false
                )

                choice(
                    title: "It's a grown-up's",
                    detail: """
                        Nothing is read from that library and nothing is written \
                        to it. Their favorites and playlists live in this app \
                        instead, and work exactly the same.
                        """,
                    isShared: true
                )

                // §3.3.6(D) permits user metadata for a function "clearly
                // disclosed to end users". Clearly disclosed is a condition, not
                // a description — and this app has kept a child's listening
                // entirely local until now, so the change in kind belongs here
                // rather than being discovered later.
                Text(
                    """
                    Either way, you can change your mind whenever you like in \
                    the admin. Switching back later picks up the library at that \
                    point rather than losing anything.

                    If you choose your kid's own library, what they keep is sent \
                    to Apple under your family's own account. Nothing about their \
                    listening goes anywhere else, ever.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
        }
    }

    private func choice(title: String, detail: String, isShared: Bool) -> some View {
        Button {
            session.setSharedDevice(isShared)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary))
        }
        .buttonStyle(.plain)
    }
}
