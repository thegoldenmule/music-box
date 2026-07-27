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

    var body: some View {
        NavigationStack {
            List {
                sandboxSection

                if let results {
                    allowedSection(results)
                    blockedSection(results)
                    diagnosticsSection(results)
                }
            }
            .navigationTitle("Aural Sandbox")
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

    private var sandboxSection: some View {
        Section("Sandbox") {
            Picker("Level", selection: modeBinding) {
                Text("1 — Allow only").tag(SandboxMode.allowOnly)
                Text("2 — Deny plus auto").tag(SandboxMode.denyPlusAuto)
                Text("3 — Report only").tag(SandboxMode.reportOnly)
            }
            Picker("Unrated", selection: unratedBinding) {
                Text("Block").tag(UnratedBehavior.block)
                Text("Allow").tag(UnratedBehavior.allow)
                Text("Inherit").tag(UnratedBehavior.inheritFromAncestor)
            }
        }
    }

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
                .swipeActions {
                    Button("Deny", role: .destructive) { deny(item) }
                }
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

    private func row(_ item: CatalogItem) -> some View {
        VStack(alignment: .leading) {
            Text(item.title)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private var modeBinding: Binding<SandboxMode> {
        Binding(get: { session.kid.mode }, set: { session.setMode($0) })
    }

    private var unratedBinding: Binding<UnratedBehavior> {
        Binding(get: { session.kid.unratedBehavior }, set: { session.setUnratedBehavior($0) })
    }

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

    private func deny(_ item: CatalogItem) {
        // Awaited, and a failure is shown. A parent who denies something and
        // gets silence must not be left believing it landed.
        if let failure = session.deny(item) {
            message = failure
        } else {
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
