import FamilyStore
import FamilySync
import SwiftUI

/// Sending and accepting invitations, from behind the gate.
///
/// **Both directions on one screen, and that is the point.** A share has an
/// owner and a joiner, and which one a device is depends entirely on who set
/// the household up first — a thing nobody knows in advance and nobody should
/// have to choose from a menu. So the screen offers both and lets the situation
/// decide.
///
/// **Behind the gate, because an invitation is the widest thing a parent can
/// do.** It hands another adult everything this app records about every child
/// in the household. That is also why the copy says so in those words rather
/// than "share with family".
struct SharingView: View {
    @Bindable var session: Session

    @State private var invitation: URL?
    @State private var participants: [ShareParticipantSummary] = []
    @State private var pastedLink = ""
    @State private var busy = false
    @State private var trouble: String?
    @State private var accepted = false

    private var sharing: any FamilySharing { session.sharing }

    var body: some View {
        Form {
            inviteSection
            acceptSection
            if !participants.isEmpty { peopleSection }
        }
        .navigationTitle("Sharing")
        .task { await refresh() }
        .alert(
            "Couldn't do that",
            isPresented: Binding(get: { trouble != nil }, set: { if !$0 { trouble = nil } }),
            actions: { Button("OK") { trouble = nil } },
            message: { Text(trouble ?? "") }
        )
    }

    // MARK: - Sending

    private var inviteSection: some View {
        Section {
            Button(busy ? "Working…" : "Create an invitation") {
                Task { await makeInvitation() }
            }
            .disabled(busy)

            if let invitation {
                ShareLink(item: invitation) {
                    Label("Send the link", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Invite a grown-up")
        } footer: {
            // The true sentence, not the comfortable one. There is no per-adult
            // scoping in this design — every participant holds the whole
            // household — so the copy has to say that plainly before somebody
            // taps it.
            Text(
                "Whoever accepts will be able to see everything this app records about every child in this family — every song they played, every search they typed, and everything that was blocked. Only send this to someone you would tell all of that."
            )
        }
    }

    private func makeInvitation() async {
        busy = true
        defer { busy = false }
        do {
            let kids = session.kids.map(\.id)
            invitation = try await sharing.invitationURL(zones: SharePlan.zones(kids: kids))
            await refresh()
        } catch {
            trouble = error.localizedDescription
        }
    }

    // MARK: - Accepting

    private var acceptSection: some View {
        Section {
            TextField("Paste the invitation link", text: $pastedLink)
                .textContentType(.URL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()

            Button(busy ? "Working…" : "Accept the invitation") {
                Task { await acceptPasted() }
            }
            .disabled(busy || URL(string: pastedLink.trimmingCharacters(in: .whitespaces)) == nil)

            if accepted {
                Label("Joined. The family's data will arrive shortly.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Join a family")
        } footer: {
            // Tapping a link launches the app and the system accepts it. This
            // exists for the device that did not receive the link — a shared
            // iPad, or a Mac where the message went to a phone — which is the
            // ordinary case rather than the odd one.
            Text(
                "If the invitation was sent to this device you can just tap the link. Paste it here for a device that did not receive it."
            )
        }
    }

    private func acceptPasted() async {
        guard let url = URL(string: pastedLink.trimmingCharacters(in: .whitespaces)) else { return }
        busy = true
        defer { busy = false }
        do {
            try await sharing.accept(url: url)
            accepted = true
            pastedLink = ""
            await refresh()
        } catch {
            trouble = error.localizedDescription
        }
    }

    // MARK: - Who is on it

    private var peopleSection: some View {
        Section {
            ForEach(participants) { person in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.isOwner ? "This family's owner" : "Grown-up")
                        // An invitation that has been sent and not taken up is
                        // its own state. Without it a parent cannot tell "they
                        // have not tapped it yet" from "it did not work".
                        Text(person.hasAccepted ? "Joined" : "Invited, not joined yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if person.permission == .readOnly {
                        Text("Read only").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if !person.isOwner {
                        Button("Remove", role: .destructive) {
                            Task { await remove(person) }
                        }
                    }
                }
            }
        } header: {
            Text("On this family")
        } footer: {
            Text(
                "Removing someone stops them receiving anything new. What is already on their device stays there — there is no way to reach back for it."
            )
        }
    }

    private func remove(_ person: ShareParticipantSummary) async {
        busy = true
        defer { busy = false }
        do {
            try await sharing.removeParticipant(person.id)
            await refresh()
        } catch {
            trouble = error.localizedDescription
        }
    }

    private func refresh() async {
        participants = (try? await sharing.participants()) ?? []
    }
}
