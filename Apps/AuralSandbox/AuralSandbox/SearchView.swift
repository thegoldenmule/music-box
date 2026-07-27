import CatalogKit
import FamilyStore
import SwiftUI

/// The slice's one screen: search, see what the policy let through, see what it
/// did not and why, and play something.
///
/// This is **not** the kid player. It shows the blocked list, the reasons, and
/// the sandbox controls, all of which are parent-side or debug-side. It exists
/// to prove the seams meet.
struct SearchView: View {
    @Bindable var session: Session

    @State private var term = ""
    @State private var results: FilteredResults?
    @State private var isSearching = false
    @State private var message: String?
    @State private var showingAdmin = false

    var body: some View {
        NavigationStack {
            List {
                if let results {
                    allowedSection(results)
                    blockedSection(results)
                    diagnosticsSection(results)
                }
            }
            .navigationTitle("Aural Sandbox")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // The only route to the parent's side, and it goes through
                    // the gate every time.
                    Button("Admin") { showingAdmin = true }
                }
            }
            .sheet(isPresented: $showingAdmin) {
                NavigationStack {
                    if session.isAdminOpen {
                        AdminView(session: session) {
                            session.closeAdmin()
                            showingAdmin = false
                            runSearch()
                        }
                    } else {
                        AdminGateView(session: session) {}
                    }
                }
            }
            .searchable(text: $term, prompt: "Search Apple Music")
            .onSubmit(of: .search) { runSearch() }
            .safeAreaInset(edge: .bottom) { PlayerBar(session: session) }
            .overlay { if isSearching { ProgressView() } }
            .alert(
                "Can't play that",
                isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { message = nil } }
                ),
                actions: { Button("OK") { message = nil } },
                message: { Text(message ?? "") }
            )
        }
    }

    // MARK: - Sections

    private func allowedSection(_ results: FilteredResults) -> some View {
        Section("Allowed (\(results.items.count))") {
            if results.items.isEmpty {
                // reachedEnd and gaveUpEarly mean different things, and saying
                // "nothing matched" when we merely stopped looking is a lie the
                // over-fetch loop went out of its way to make avoidable.
                Text(
                    results.gaveUpEarly
                        ? "Nothing yet — we stopped looking before the page filled."
                        : "Nothing matched."
                )
                .foregroundStyle(.secondary)
            }
            ForEach(results.items, id: \.id) { item in
                Button {
                    play(item)
                } label: {
                    row(item)
                }
                // Both gestures, because a swipe is not discoverable and this
                // is the control that tests the safety-critical case.
                .swipeActions(edge: .trailing) { denyButtons(for: item) }
                .contextMenu { denyButtons(for: item) }
            }
        }
    }

    private func blockedSection(_ results: FilteredResults) -> some View {
        Section("Blocked (\(results.blocked.count))") {
            ForEach(results.blocked, id: \.item.id) { blocked in
                VStack(alignment: .leading, spacing: 2) {
                    row(blocked.item)
                    Text(describe(blocked.reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing) { undoButton(blocked.reason) }
                .contextMenu { undoButton(blocked.reason) }
            }
        }
    }

    /// Undo the rule that blocked this row — offered only when a rule is what
    /// blocked it.
    ///
    /// A row blocked for being explicit or unrated has no rule behind it, so
    /// there is nothing here to undo; that is a sandbox-level or unrated-
    /// behavior change, made above. Removing the *matching* rule rather than
    /// allowing this one item matters: the deny may sit on the artist, and the
    /// thing the parent wants back is the artist, not one track by them.
    @ViewBuilder
    private func undoButton(_ reason: Reason) -> some View {
        if case .deniedByParent(let id) = reason {
            Button("Remove this deny", role: .destructive) {
                if let failure = session.removeEntries(matching: id) {
                    message = failure
                } else {
                    runSearch()
                }
            }
        }
    }

    private func diagnosticsSection(_ results: FilteredResults) -> some View {
        Section("Diagnostics") {
            LabeledContent("Requests", value: "\(results.requestCount)")
            LabeledContent("Reached end", value: results.reachedEnd ? "yes" : "no")
            LabeledContent("Gave up early", value: results.gaveUpEarly ? "yes" : "no")
            // Research question 1: how often is contentRating nil? This is the
            // cheap version of Tools/RatingProbe, and the number it shows
            // decides the UnratedBehavior default and whether an over-fetch
            // multiplier of 3 is anywhere near right.
            LabeledContent("Unrated seen", value: "\(unratedCount(results))")
            // Whether ancestry actually resolved. MusicKit logs "A
            // MusicIdentifierSet with empty string … is being used" freely, and
            // that log cannot distinguish harmless noise from lineage silently
            // failing to arrive. These two counts can: a deny on an artist only
            // reaches their tracks if the artist count matches the result
            // count.
            LabeledContent("With album", value: "\(lineageCount(results, .album))")
            LabeledContent("With artist", value: "\(lineageCount(results, .artist))")
            LabeledContent("Judged", value: "\(results.items.count + results.blocked.count)")
        }
    }

    /// Deny this song, or the artist behind it.
    ///
    /// **The artist button only appears when the item carries an artist
    /// ancestor.** That is deliberate and diagnostic: if it never appears,
    /// ancestry is not resolving, and artist-level denies cannot work at all —
    /// which is open question 13, answered by looking rather than by reading a
    /// log.
    ///
    /// There is no album button. A song's `CatalogItem` carries the artist name
    /// as its subtitle but never the album's title, and `displayName` is copied
    /// at write time and never refreshed — so an album deny here would store a
    /// permanently wrong name. The real admin resolves the album first.
    @ViewBuilder
    private func denyButtons(for item: CatalogItem) -> some View {
        if let artist = item.ancestors.first(where: { $0.id.kind == .artist }) {
            Button("Deny artist", role: .destructive) {
                deny(artist.id, name: item.subtitle ?? "Artist")
            }
        }
        Button("Deny song", role: .destructive) {
            deny(item.id, name: item.title, artwork: item.artworkURL)
        }
    }

    private func row(_ item: CatalogItem) -> some View {
        VStack(alignment: .leading) {
            Text(item.title)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func runSearch() {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }

        Task {
            isSearching = true
            defer { isSearching = false }
            do {
                results = try await session.search(term: term)
            } catch {
                message = Session.message(for: error)
            }
        }
    }

    private func play(_ item: CatalogItem) {
        Task {
            do {
                try await session.play(item, origin: .search(term: term))
            } catch let refused as Session.Refused {
                message = describe(refused.reason)
            } catch {
                message = Session.message(for: error)
            }
        }
    }

    private func deny(_ id: CatalogID, name: String, artwork: URL? = nil) {
        // Awaited, and a failure is shown. A parent who denies something and
        // gets silence must not be left believing it landed.
        if let failure = session.deny(id, displayName: name, artworkURL: artwork) {
            message = failure
        } else {
            // Re-run so the effect is visible immediately: denying an artist
            // should move every other track by them into Blocked.
            runSearch()
        }
    }

    private func unratedCount(_ results: FilteredResults) -> Int {
        results.items.filter { $0.rating == nil }.count
            + results.blocked.filter { $0.item.rating == nil }.count
    }

    /// How many judged items carry a non-empty ancestor of this kind.
    private func lineageCount(_ results: FilteredResults, _ kind: ItemKind) -> Int {
        let judged = results.items + results.blocked.map(\.item)
        return judged.filter { item in
            item.ancestors.contains { $0.id.kind == kind && !$0.id.rawValue.isEmpty }
        }
        .count
    }

    private func describe(_ reason: Reason) -> String {
        switch reason {
        case .notOnAllowList: "Not on the allow list."
        case .deniedByParent(let id): "Denied: \(id)."
        case .explicitContent: "Marked explicit."
        case .unrated: "No rating available."
        }
    }

    private func describe(_ reason: BlockReason) -> String {
        switch reason {
        case .notOnAllowList: "Not on the allow list."
        case .deniedByParent(let id): "Denied: \(id)."
        case .explicitContent: "Marked explicit."
        case .unrated: "No rating available."
        case .restrictedOutsideApp:
            "Blocked by something outside this app — check Screen Time."
        }
    }
}
