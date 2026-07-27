import CatalogKit
import PolicyEngine
import SwiftUI

/// Search the catalog and put something on a list.
///
/// **This search is unfiltered, on purpose.** It is the one place in the app
/// that does not consult the policy engine. A parent choosing what to deny has
/// to be able to see the thing they mean to deny — running it through the kid's
/// policy would hide exactly the items they came here for, and level 1 would
/// return nothing at all.
///
/// Nothing here reaches the kid's side. `Session.searchUnfiltered` is the only
/// entry point, and the player never calls it.
struct ListEditorView: View {
    @Bindable var session: Session
    let kind: PolicyEntry.Kind
    var onClose: () -> Void

    @State private var term = ""
    @State private var kinds: Set<ItemKind> = [.artist, .album, .song]
    @State private var results: [CatalogItem] = []
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                // Artists first: the deny that actually holds is the one on the
                // artist, since it reaches everything of theirs including next
                // month's release.
                Picker("Looking for", selection: kindSelection) {
                    Text("Artists").tag(Set<ItemKind>([.artist]))
                    Text("Albums").tag(Set<ItemKind>([.album]))
                    Text("Songs").tag(Set<ItemKind>([.song]))
                    Text("Everything").tag(Set<ItemKind>([.artist, .album, .song]))
                }
                .pickerStyle(.segmented)
            }

            Section("Results") {
                if results.isEmpty && !isSearching {
                    Text("Search Apple Music for something to \(kind == .allow ? "add" : "deny").")
                        .foregroundStyle(.secondary)
                }
                ForEach(results, id: \.id) { item in
                    Button {
                        add(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(subtitle(for: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(kind == .allow ? "Add to allowed" : "Add to denied")
        .searchable(text: $term, prompt: "Search all of Apple Music")
        .onSubmit(of: .search) { runSearch() }
        .overlay { if isSearching { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onClose() }
            }
        }
        .alert(
            "Couldn't do that",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
            actions: { Button("OK") { message = nil } },
            message: { Text(message ?? "") }
        )
    }

    private var kindSelection: Binding<Set<ItemKind>> {
        Binding(
            get: { kinds },
            set: {
                kinds = $0
                if !term.isEmpty { runSearch() }
            }
        )
    }

    private func subtitle(for item: CatalogItem) -> String {
        var parts = [item.id.kind.rawValue]
        if let subtitle = item.subtitle { parts.append(subtitle) }
        // Say so where the catalog says so. A parent denying by hand benefits
        // from seeing which results are the ones level 2 would have caught.
        if item.rating == .explicit { parts.append("explicit") }
        return parts.joined(separator: " · ")
    }

    private func runSearch() {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }

        Task {
            isSearching = true
            defer { isSearching = false }
            session.touchAdmin()
            do {
                results = try await session.searchUnfiltered(term: term, kinds: kinds)
            } catch {
                message = Session.message(for: error)
            }
        }
    }

    private func add(_ item: CatalogItem) {
        session.touchAdmin()
        let failure = session.addEntry(
            kind: kind,
            id: item.id,
            displayName: item.title,
            artworkURL: item.artworkURL
        )
        if let failure {
            message = failure
        } else {
            onClose()
        }
    }
}
