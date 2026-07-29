import CatalogKit
import FamilyStore
import PolicyEngine
import SwiftUI

/// The parent's side: kids, the sandbox level, and the lists.
///
/// Reached only through ``AdminGateView``, and closed on dismissal rather than
/// left open behind the sheet.
struct AdminView: View {
    @Bindable var session: Session
    var onClose: () -> Void

    @State private var newKidName = ""
    @State private var message: String?
    @State private var editing: PolicyEntry.Kind?
    @State private var suggesting = false

    /// The suggestion a swipe is proposing to delete, held until it is
    /// confirmed. See ``withdrawConfirmation``.
    @State private var withdrawing: SuggestionRow?

    var body: some View {
        Form {
            kidsSection
            reviewSection
            sandboxSection
            // Above the lists, and grouped with them rather than with the
            // report: a suggestion widens what the kid reaches, so it belongs
            // beside the other things that do.
            suggestionsSection
            listSection(.allow)
            listSection(.deny)
            deviceSection

            Section {
                NavigationLink("Diagnostics") { SearchView(session: session) }
            } footer: {
                Text(
                    "Unfiltered counts and reasons, for answering the questions the specs still list as open. Nothing here belongs on the kid's side."
                )
            }
        }
        .navigationTitle("Admin")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onClose() }
            }
        }
        .sheet(item: $editing) { kind in
            NavigationStack {
                ListEditorView(session: session, kind: kind) { editing = nil }
            }
        }
        .sheet(isPresented: $suggesting) {
            NavigationStack {
                SuggestionEditorView(session: session) { suggesting = false }
            }
        }
        .modifier(withdrawConfirmation)
        .alert(
            "Couldn't save",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
            actions: { Button("OK") { message = nil } },
            message: { Text(message ?? "") }
        )
        // Any interaction here is activity; the session lapses on idleness, not
        // on elapsed time.
        .onAppear { session.touchAdmin() }
    }

    // MARK: - Kids

    private var kidsSection: some View {
        Section("Kids") {
            ForEach(session.kids, id: \.id) { kid in
                Button {
                    session.switchTo(kid)
                } label: {
                    HStack {
                        Text(kid.name)
                        Spacer()
                        if kid.id == session.kid.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { show(session.delete(kid)) }
                }
            }

            HStack {
                TextField("New kid's name", text: $newKidName)
                Button("Add") {
                    show(session.addKid(named: newKidName.trimmingCharacters(in: .whitespaces)))
                    newKidName = ""
                }
                .disabled(newKidName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Review

    /// The one screen in the app that shows everything.
    ///
    /// Above the lists rather than below them, because reading what happened is
    /// what tells a parent whether the lists are in the right place — and
    /// because approve-from-report is how a level 1 list is meant to be built.
    private var reviewSection: some View {
        Section {
            NavigationLink {
                ReviewView(session: session, kid: session.kid)
            } label: {
                Label("Review Activity", systemImage: "list.bullet.rectangle")
            }
        }
    }

    // MARK: - Level

    private var sandboxSection: some View {
        Section {
            Picker("Level", selection: modeBinding) {
                Text("1 — Only what I add").tag(SandboxMode.allowOnly)
                Text("2 — Everything except explicit and my denies").tag(SandboxMode.denyPlusAuto)
                Text("3 — Everything, still logged").tag(SandboxMode.reportOnly)
            }
            Picker("Unrated tracks", selection: unratedBinding) {
                Text("Block").tag(UnratedBehavior.block)
                Text("Allow").tag(UnratedBehavior.allow)
                Text("Follow the album").tag(UnratedBehavior.inheritFromAncestor)
            }
        } header: {
            Text("\(session.kid.name)'s sandbox")
        } footer: {
            // The spec is explicit that level 2 copy must never imply the
            // explicit tag covers themes. It covers lyrics, and only lyrics.
            Text(explanation(for: session.kid.mode))
        }
    }

    private func explanation(for mode: SandboxMode) -> String {
        switch mode {
        case .allowOnly:
            "Your kid sees only what you have added, and cannot search. Nothing else in Apple Music is reachable."
        case .denyPlusAuto:
            "Your kid can search all of Apple Music except tracks marked explicit and anything you have denied. Apple's explicit tag describes lyrics, not subject matter — a clean-rated song can still be about anything."
        case .reportOnly:
            "No limits at all. Everything is still recorded so you can see what they listened to."
        }
    }

    // MARK: - This device

    /// The same two questions onboarding asked, changeable.
    ///
    /// **Per device, not per family, and not per kid.** They describe the Apple
    /// Music library signed in here, so they are never synced — a second device
    /// has its own answers and would be handed ones that are false there.
    ///
    /// Two switches rather than the single derived one, so this screen and
    /// onboarding ask the same thing. A lone "is this my kid's own library?"
    /// switch would be a third wording of a question already asked twice, and
    /// the one wording a parent cannot answer without working out what it means.
    private var deviceSection: some View {
        Section {
            Toggle("Sharing this device with your child", isOn: sharesDeviceBinding)
            Toggle("Your child has their own Apple Music account", isOn: ownAccountBinding)
                // Moot on a shared device, exactly as in onboarding: the account
                // signed in is a grown-up's and the library is theirs whichever
                // way this points.
                .disabled(session.deviceLibrary.sharesDeviceWithChild)
        } header: {
            Text("This device")
        } footer: {
            Text(
                session.deviceLibrary.isSharedDevice
                    ? "Their favorites and playlists live in this app only. Nothing is read from the Apple Music library on this device and nothing is written to it."
                    : "Their favorites and playlists become real items in your child's Apple Music library, and whatever is already in it shows up on their shelf — filtered by their level, like everything else. What they keep is sent to Apple under your family's account and nowhere else."
            )
        }
    }

    // MARK: - Lists

    // MARK: - Suggestions

    /// What the parent has put in front of this kid, and what the kid passed on.
    ///
    /// The two groups are the whole feedback loop. A dismissal is otherwise
    /// invisible — the tile simply stops being there — and a parent left
    /// re-suggesting blindly cannot tell "they said no" from "I never got round
    /// to it."
    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            if session.suggestions.isEmpty {
                Text("Nothing suggested yet.").foregroundStyle(.secondary)
            }
            ForEach(session.suggestions) { row in
                SuggestionRowLabel(row: row)
                    .swipeActions {
                        Button("Remove", role: .destructive) { withdrawing = row }
                    }
            }

            Button("Suggest something") { suggesting = true }
        } header: {
            Text("Suggested")
        } footer: {
            Text(
                "Anything you suggest becomes reachable for \(session.kid.name), whatever level they are on. A deny still wins."
            )
        }

        if !session.dismissedSuggestions.isEmpty {
            Section {
                ForEach(session.dismissedSuggestions) { row in
                    SuggestionRowLabel(row: row)
                        .swipeActions {
                            Button("Remove", role: .destructive) { withdrawing = row }
                            Button("Suggest again") {
                                show(session.restoreSuggestion(row))
                            }
                        }
                }
            } header: {
                Text("Passed on")
            } footer: {
                Text(
                    "\(session.kid.name) said no thanks to these, so they are not reachable through a suggestion any more. Swipe to offer one again."
                )
            }
        }
    }

    /// Confirms a withdrawal before it happens.
    ///
    /// Withdrawing is not the opposite of suggesting — it is a delete. The row
    /// goes, and with it the note the parent wrote, the fact that the kid passed
    /// on it, and every track of a snapshotted playlist, which can be forty rows
    /// that took a round trip each to resolve. "Suggest again" is the undo for a
    /// dismissal; there is no undo for this.
    ///
    /// A single modifier rather than one per section, so the two lists cannot
    /// end up asking differently.
    private var withdrawConfirmation: some ViewModifier {
        WithdrawConfirmation(row: $withdrawing) { row in
            show(session.withdrawSuggestion(row))
        }
    }

    private func listSection(_ kind: PolicyEntry.Kind) -> some View {
        let entries = session.kid.entries.filter { $0.kind == kind.rawValue }

        return Section(kind == .allow ? "Allowed" : "Denied") {
            if entries.isEmpty {
                Text(
                    kind == .allow
                        ? "Nothing added yet."
                        : "Nothing denied yet."
                )
                .foregroundStyle(.secondary)
            }
            // Grouped by type, because "this artist" and "this one song" are
            // different promises and a flat list hides which you made.
            ForEach(ItemKind.allCases, id: \.self) { itemKind in
                let matching = entries.filter { $0.itemKind == itemKind.rawValue }
                if !matching.isEmpty {
                    ForEach(matching, id: \.id) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayName)
                            Text(itemKind.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                show(session.removeEntry(record))
                            }
                        }
                    }
                }
            }

            Button(kind == .allow ? "Add something" : "Deny something") { editing = kind }
        }
    }

    // MARK: -

    private var modeBinding: Binding<SandboxMode> {
        Binding(get: { session.kid.mode }, set: { session.setMode($0) })
    }

    private var unratedBinding: Binding<UnratedBehavior> {
        Binding(get: { session.kid.unratedBehavior }, set: { session.setUnratedBehavior($0) })
    }

    /// Each switch writes both answers, because the stored value is derived from
    /// the pair and half of a pair is not a state.
    private var sharesDeviceBinding: Binding<Bool> {
        Binding(
            get: { session.deviceLibrary.sharesDeviceWithChild },
            set: {
                session.setDeviceAnswers(
                    sharesDevice: $0,
                    childHasOwnAccount: session.deviceLibrary.childHasOwnAccount
                )
            }
        )
    }

    private var ownAccountBinding: Binding<Bool> {
        Binding(
            get: { session.deviceLibrary.childHasOwnAccount },
            set: {
                session.setDeviceAnswers(
                    sharesDevice: session.deviceLibrary.sharesDeviceWithChild,
                    childHasOwnAccount: $0
                )
            }
        )
    }

    private func show(_ failure: String?) {
        // A parent who edits a list and gets silence must not be left believing
        // it landed. Every one of these writes is awaited.
        if let failure { message = failure }
    }
}

extension PolicyEntry.Kind: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// Asks before deleting a suggestion, and says what goes with it.
///
/// A modifier rather than an inline `confirmationDialog` because both lists in
/// the suggestions section feed it, and a swipe in either should get the same
/// question.
struct WithdrawConfirmation: ViewModifier {
    @Binding var row: SuggestionRow?
    let onConfirm: (SuggestionRow) -> Void

    /// One verb, everywhere. The swipe says Remove, the question asks Remove and
    /// the button that answers it says Remove — on this screen and on the kid's.
    /// It said "Take back" here, which is a better description of withdrawing a
    /// suggestion and a worse thing to read on a button under a row labelled
    /// something else.
    func body(content: Content) -> some View {
        content.confirmationDialog(
            row.map { "Remove “\($0.displayName)”?" } ?? "",
            isPresented: Binding(get: { row != nil }, set: { if !$0 { row = nil } }),
            titleVisibility: .visible,
            presenting: row
        ) { row in
            Button("Remove", role: .destructive) {
                onConfirm(row)
                self.row = nil
            }
            Button("Cancel", role: .cancel) { self.row = nil }
        } message: { row in
            Text(message(for: row))
        }
    }

    private func message(for row: SuggestionRow) -> String {
        var parts = ["This deletes the suggestion and takes back the reach it granted."]
        // The count is the part a parent cannot see coming. Forty resolved
        // tracks look like one row in this list.
        if row.itemKind == .playlist, row.entries.count > 1 {
            parts.append("The \(row.entries.count) songs matched for it go too.")
        }
        if row.isDismissed {
            parts.append("“Suggest again” keeps it instead.")
        }
        return parts.joined(separator: " ")
    }
}

/// One suggestion, as the parent sees it in a list.
///
/// A snapshot playlist reads as its track count rather than its kind, because
/// "playlist" is the least interesting true thing about it: the parent knows
/// what they picked, and what they cannot see from the name is how much of it
/// survived being matched against the catalog.
struct SuggestionRowLabel: View {
    let row: SuggestionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.displayName)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if row.itemKind == .playlist, !row.entries.isEmpty {
            parts.append(row.entries.count == 1 ? "1 song" : "\(row.entries.count) songs")
        } else {
            parts.append(row.itemKind.rawValue)
        }
        if let subtitle = row.subtitle { parts.append(subtitle) }
        if let note = row.note, !note.isEmpty { parts.append("“\(note)”") }
        return parts.joined(separator: " · ")
    }
}
