import CatalogKit
import FamilyStore
import PolicyEngine
import SwiftUI

/// Where a parent is picking from.
enum SuggestionPickSource: String, CaseIterable, Identifiable {
    case catalog
    case library

    var id: String { rawValue }

    var label: String {
        switch self {
        case .catalog: "Apple Music"
        case .library: "Your library"
        }
    }
}

/// Pick things out of Apple Music and put them in front of the kid.
///
/// **The catalog search here is unfiltered**, for the reason ``ListEditorView``'s
/// is: a parent choosing what to hand their child has to be able to see it, and
/// running the search through the kid's own policy would hide the things they
/// came here for — at level 1 it would return nothing at all.
///
/// Multi-select with a draft, where the list editor commits one item at a time.
/// The difference is the task: denying is usually one artist, and suggesting is
/// usually an evening's worth of things. It is also where the draft earns its
/// keep, because the confirm step is the only place a parent is told what their
/// kid will actually be able to play.
struct SuggestionEditorView: View {
    @Bindable var session: Session
    var onClose: () -> Void

    /// **Their own library first.** Catalog search is the more powerful half and
    /// the wrong thing to open on: a parent introducing their kid to music is
    /// almost always starting from records they already know they like, and
    /// making them type the name of one they own is asking them to look up an
    /// answer they came here holding.
    @State private var source: SuggestionPickSource = .library
    @State private var term = ""
    @State private var kinds: Set<ItemKind> = [.artist, .album, .song, .playlist]
    @State private var results: [CatalogItem] = []
    @State private var draft: [SuggestionDraftItem] = []
    @State private var isSearching = false
    @State private var message: String?
    @State private var confirming = false

    /// Hidden only on a definite `false`. See ``Session/hasCloudLibrary``.
    private var canPickFromLibrary: Bool { session.hasCloudLibrary != false }

    var body: some View {
        VStack(spacing: 0) {
            if canPickFromLibrary {
                Picker("Pick from", selection: $source) {
                    ForEach(SuggestionPickSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            switch source {
            case .catalog:
                catalogPicker
            case .library:
                LibraryPicker(session: session, draft: $draft, message: $message)
            }
        }
        .navigationTitle("Suggest something")
        // Sync Library being off hides the tab, and the default has to follow it
        // rather than leave the sheet parked on a half that is not on screen.
        .onAppear { if !canPickFromLibrary { source = .catalog } }
        .onChange(of: canPickFromLibrary) { if !canPickFromLibrary { source = .catalog } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onClose() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Next (\(draft.count))") { confirming = true }
                    .disabled(draft.isEmpty)
            }
        }
        .sheet(isPresented: $confirming) {
            NavigationStack {
                SuggestionConfirmView(session: session, items: draft) { failure in
                    confirming = false
                    if let failure {
                        message = failure
                    } else {
                        onClose()
                    }
                }
            }
        }
        .alert(
            "Couldn't do that",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
            actions: { Button("OK") { message = nil } },
            message: { Text(message ?? "") }
        )
    }

    // MARK: - Catalog search

    private var catalogPicker: some View {
        List {
            Section {
                Picker("Looking for", selection: kindSelection) {
                    Text("Artists").tag(Set<ItemKind>([.artist]))
                    Text("Albums").tag(Set<ItemKind>([.album]))
                    Text("Songs").tag(Set<ItemKind>([.song]))
                    Text("Playlists").tag(Set<ItemKind>([.playlist]))
                }
                .pickerStyle(.segmented)
            }

            Section("Results") {
                if results.isEmpty && !isSearching {
                    Text("Search Apple Music for something to suggest.")
                        .foregroundStyle(.secondary)
                }
                ForEach(results, id: \.id) { item in
                    PickRow(
                        title: item.title,
                        detail: subtitle(for: item),
                        isPicked: isPicked(item)
                    ) {
                        toggle(item)
                    }
                }
            }
        }
        .searchable(text: $term, prompt: "Search all of Apple Music")
        .onSubmit(of: .search) { runSearch() }
        .overlay { if isSearching { ProgressView() } }
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

    private func isPicked(_ item: CatalogItem) -> Bool {
        draft.contains { $0 == .catalog(item) }
    }

    private func toggle(_ item: CatalogItem) {
        session.touchAdmin()
        if isPicked(item) {
            draft.removeAll { $0 == .catalog(item) }
        } else {
            draft.append(.catalog(item))
        }
    }

    private func subtitle(for item: CatalogItem) -> String {
        var parts = [item.id.kind.rawValue]
        if let subtitle = item.subtitle { parts.append(subtitle) }
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
}

/// The parent's own Apple Music library, as something to suggest out of.
///
/// **Everything here resolves to a catalog item before it reaches the draft**,
/// which is the rule that makes one namespace possible. What that costs is a
/// round trip per tap — so a row shows a spinner while it resolves, and says so
/// when it cannot. The three kinds resolve three different ways:
///
/// - Songs and albums by ISRC and UPC, the path that already existed.
/// - Playlists track by track, keeping the name. A playlist has no code of its
///   own and never will.
/// - Artists by resolving a sample of their songs and reading the artist off the
///   results, which needs no new matching rule at all — see ``ArtistVote``.
struct LibraryPicker: View {
    @Bindable var session: Session
    @Binding var draft: [SuggestionDraftItem]
    @Binding var message: String?

    private enum Kind: String, CaseIterable, Identifiable {
        case playlists, artists, albums, songs
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @State private var kind: Kind = .playlists
    @State private var playlists: [LibraryPlaylist] = []
    @State private var items: [CatalogKit.LibraryItem] = []
    @State private var isLoading = false
    @State private var resolving: Set<String> = []
    @State private var added: Set<String> = []

    var body: some View {
        List {
            Section {
                Picker("Looking for", selection: kindSelection) {
                    ForEach(Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section(kind == .playlists ? "Your playlists" : "In your library") {
                if isLoading {
                    ProgressView()
                } else if isEmpty {
                    Text("Nothing here. Sync Library has to be on for this.")
                        .foregroundStyle(.secondary)
                }

                if kind == .playlists {
                    ForEach(playlists) { playlist in
                        PickRow(
                            title: playlist.name,
                            detail: detail(for: playlist),
                            isPicked: added.contains(playlist.id),
                            isBusy: resolving.contains(playlist.id)
                        ) {
                            resolve(playlist)
                        }
                    }
                } else {
                    ForEach(items) { item in
                        PickRow(
                            title: item.title,
                            detail: item.subtitle ?? item.kind.rawValue,
                            isPicked: added.contains(item.id),
                            isBusy: resolving.contains(item.id)
                        ) {
                            resolve(item)
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private var isEmpty: Bool {
        kind == .playlists ? playlists.isEmpty : items.isEmpty
    }

    private var kindSelection: Binding<Kind> {
        Binding(
            get: { kind },
            set: {
                kind = $0
                Task { await load() }
            }
        )
    }

    private func detail(for playlist: LibraryPlaylist) -> String {
        var parts: [String] = []
        // The parent knows what they made; what they cannot see from a name is
        // which of these are Apple's.
        parts.append(playlist.isPersonal ? "yours" : playlist.curatorName ?? "Apple Music")
        if let count = playlist.trackCount {
            parts.append(count == 1 ? "1 song" : "\(count) songs")
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        session.touchAdmin()
        do {
            switch kind {
            case .playlists:
                playlists = try await session.libraryPlaylists()
            case .artists:
                items = try await session.libraryItems(kinds: [.artist])
            case .albums:
                items = try await session.libraryItems(kinds: [.album])
            case .songs:
                items = try await session.libraryItems(kinds: [.song])
            }
        } catch {
            message = Session.message(for: error)
        }
    }

    private func resolve(_ playlist: LibraryPlaylist) {
        Task {
            resolving.insert(playlist.id)
            defer { resolving.remove(playlist.id) }
            session.touchAdmin()
            do {
                let imported = try await session.resolveLibraryPlaylist(playlist)
                guard !imported.resolved.isEmpty else {
                    message =
                        "None of the songs in “\(playlist.name)” are on Apple Music, so there is nothing to suggest."
                    return
                }
                draft.append(
                    .snapshot(
                        name: playlist.name,
                        songs: imported.resolved,
                        discarded: imported.discarded
                    )
                )
                added.insert(playlist.id)
            } catch {
                message = Session.message(for: error)
            }
        }
    }

    private func resolve(_ item: CatalogKit.LibraryItem) {
        Task {
            resolving.insert(item.id)
            defer { resolving.remove(item.id) }
            session.touchAdmin()
            do {
                if item.kind == .artist {
                    switch try await session.resolveLibraryArtist(item) {
                    case .resolved(let resolved):
                        draft.append(.catalog(resolved))
                        added.insert(item.id)
                    case .ambiguous:
                        // Refused rather than guessed. A suggestion is an allow,
                        // and the wrong artist here hands a kid a catalogue
                        // nobody chose.
                        message =
                            "Couldn't tell which “\(item.title)” this is. Search Apple Music for them instead."
                    case .notInAppleMusic:
                        message = "“\(item.title)” isn't on Apple Music."
                    }
                    return
                }

                let imported = try await session.resolveFromLibrary([item])
                guard let resolved = imported.resolved.first else {
                    message = reason(for: imported.discarded.first?.reason, name: item.title)
                    return
                }
                draft.append(.catalog(resolved))
                added.insert(item.id)
            } catch {
                message = Session.message(for: error)
            }
        }
    }

    /// A discard is not a refusal — the parent can still find it by searching,
    /// if Apple Music carries it. So each reason says which of the two it is.
    private func reason(for discard: DiscardReason?, name: String) -> String {
        switch discard {
        case .noIdentifier:
            "“\(name)” has no Apple Music code — it looks like your own file, so there is nothing to match it to."
        case .notInAppleMusic:
            "“\(name)” isn't on Apple Music, so it can't be played in this app."
        case .unsupportedKind, nil:
            "Couldn't match “\(name)” to Apple Music."
        }
    }
}

/// A row that can be picked, is picking, or has been picked.
struct PickRow: View {
    let title: String
    let detail: String
    let isPicked: Bool
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isBusy {
                    ProgressView()
                } else if isPicked {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
        }
        .disabled(isBusy)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// The draft, before it commits.
///
/// Two things happen here that cannot happen on the results list. The parent
/// writes one line the kid will read, and — the load-bearing half — every
/// container is counted, so "12 of 14 songs — the rest are explicit" is on screen
/// before the tap rather than discovered three weeks later.
struct SuggestionConfirmView: View {
    @Bindable var session: Session
    let items: [SuggestionDraftItem]

    /// `nil` on success, a message on failure.
    var onFinish: (String?) -> Void

    @State private var note = ""
    @State private var previews: [CatalogID: SuggestionPreview] = [:]
    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(detail(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Suggesting to \(session.kid.name)")
            } footer: {
                Text(
                    "Suggesting something also makes it reachable, at every level. If \(session.kid.name) passes on it, that goes away again."
                )
            }

            Section {
                TextField("Say why (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
            } footer: {
                Text("\(session.kid.name) sees this.")
            }
        }
        .navigationTitle("Suggest")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { onFinish(nil) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Suggest") { commit() }
                    .disabled(isWorking)
            }
        }
        .overlay { if isWorking { ProgressView() } }
        .task { await loadPreviews() }
    }

    /// What the parent is told about one row.
    ///
    /// A snapshot answers out of its own arithmetic — the matching already
    /// happened. A catalog container has to be counted against the kid's level,
    /// and that count is deliberately absent rather than guessed at while it
    /// loads: a number that appears and then changes is worse than one that
    /// arrives late.
    private func detail(for item: SuggestionDraftItem) -> String {
        if let sentence = item.snapshotSentence { return sentence }
        guard case .catalog(let catalogItem) = item else { return "" }
        var parts = [catalogItem.id.kind.rawValue]
        if let subtitle = catalogItem.subtitle { parts.append(subtitle) }
        if let preview = previews[catalogItem.id] { parts.append(preview.sentence) }
        return parts.joined(separator: " · ")
    }

    /// One at a time, and filling in as they arrive.
    ///
    /// Serial rather than a task group: a parent picks a handful of things, not
    /// a hundred, and each row updates the moment its own count lands — so the
    /// sheet is never waiting on the slowest of them to draw the rest.
    private func loadPreviews() async {
        for item in items {
            guard case .catalog(let catalogItem) = item else { continue }
            if let preview = await session.suggestionPreview(for: catalogItem) {
                previews[catalogItem.id] = preview
            }
        }
    }

    private func commit() {
        Task {
            isWorking = true
            defer { isWorking = false }
            session.touchAdmin()
            let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            for item in items {
                if let failure = await session.suggest(item, note: note.isEmpty ? nil : note) {
                    onFinish(failure)
                    return
                }
            }
            onFinish(nil)
        }
    }
}
