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

    var body: some View {
        Form {
            kidsSection
            sandboxSection
            listSection(.allow)
            listSection(.deny)
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

    // MARK: - Lists

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

    private func show(_ failure: String?) {
        // A parent who edits a list and gets silence must not be left believing
        // it landed. Every one of these writes is awaited.
        if let failure { message = failure }
    }
}

extension PolicyEntry.Kind: @retroactive Identifiable {
    public var id: String { rawValue }
}
