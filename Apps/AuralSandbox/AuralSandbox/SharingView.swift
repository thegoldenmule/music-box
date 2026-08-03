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

    /// Who the next invitation is for. A co-parent and a child get different
    /// zones at different permissions, so this is not cosmetic — see
    /// ``SharePlan``.
    @State private var inviting: InviteTarget = .grownUp

    /// Which side of the share this device is on. **Nothing owner-side is drawn
    /// until this is known**, because the buttons are not merely inapplicable on
    /// a joined device — they write to the wrong database and mint a second,
    /// empty household. See ``HouseholdSide``.
    @State private var side: HouseholdSide?

    private enum InviteTarget: Hashable {
        case grownUp
        case kid(UUID)
    }

    private var sharing: any FamilySharing { session.sharing }

    private var owns: Bool { side?.ownsTheHousehold ?? false }

    var body: some View {
        Form {
            syncSection
            if owns {
                inviteSection
                if !participants.isEmpty { peopleSection }
            } else if side != nil {
                joinedSection
            }
            acceptSection
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

    /// What a device that joined somebody else's family sees instead of the
    /// invite controls.
    ///
    /// **It says who is in charge rather than hiding the section**, because the
    /// absence of a button is indistinguishable from a bug — and the answer to
    /// "why can't I invite anyone" is a fact about the household, not a failure.
    private var joinedSection: some View {
        Section {
            Label("This device joined a family somebody else set up.", systemImage: "person.2")
                .foregroundStyle(.secondary)
        } header: {
            Text("This family")
        } footer: {
            Text(
                "Whoever set the family up is the one who can invite or remove people. Everything else works the same here."
            )
        }
    }

    private var syncSection: some View {
        Section {
            Button("Sync now") { Task { await session.syncNow() } }
            let status = session.syncEngine?.status ?? SyncStatus()
            if status.pendingCount > 0 {
                Text("\(status.pendingCount) record(s) waiting to go out")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let last = status.lastSucceeded {
                Text("Last sent \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let trouble = status.lastError {
                Text(trouble).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("This device")
        } footer: {
            // Manual on purpose. See `Session.syncEngine`.
            Text("Sync does not run on its own yet.")
        }
    }

    // MARK: - Sending

    private var inviteSection: some View {
        Section {
            Picker("Invite", selection: $inviting) {
                Text("Another grown-up").tag(InviteTarget.grownUp)
                ForEach(session.kids, id: \.id) { kid in
                    Text("\(kid.name)'s own device").tag(InviteTarget.kid(kid.id))
                }
            }

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
            // Two different sentences, because they are two different asks and
            // the second is not a smaller version of the first.
            Text(
                inviting == .grownUp
                    ? "Whoever accepts will be able to see everything this app records about every child in this family — every song they played, every search they typed, and everything that was blocked. Only send this to someone you would tell all of that."
                    : "This lets your child use their own Apple Account on their own device. They will be able to keep their own favourites and playlists, and they will not be able to change what they are allowed to reach — or see anything of a brother or sister's."
            )
        }
    }

    private var role: ShareRole {
        switch inviting {
        case .grownUp: .coParent
        case .kid(let id): .child(id)
        }
    }

    private func makeInvitation() async {
        busy = true
        defer { busy = false }
        do {
            invitation = try await sharing.invitation(
                for: role, kids: session.kids.map(\.id))
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

    /// Reads the roster, and finishes any invitation that has been accepted
    /// since last time.
    ///
    /// **The second step runs here rather than on acceptance, because there is
    /// no acceptance to hook.** A share does not call back; the owner's device
    /// finds out somebody joined by looking. So this happens whenever the screen
    /// opens, it is idempotent, and doing nothing is the normal outcome.
    private func refresh() async {
        // First, because everything below is owner-side and would write into
        // the wrong database on a device that joined.
        side = try? await sharing.side()

        participants = (try? await sharing.participants()) ?? []
        guard owns else { return }

        _ = try? await sharing.reconcileGrants(for: .coParent, kids: session.kids.map(\.id))
        for kid in session.kids {
            _ = try? await sharing.reconcileGrants(for: .child(kid.id), kids: session.kids.map(\.id))
        }
    }
}
