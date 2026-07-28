import CatalogKit
import FamilyStore
import SwiftUI

/// The diagnostics screen, reached only from the admin.
///
/// This was the app's one screen before the kid player existed. It stays
/// because the numbers on it are how the remaining research questions get
/// answered — unrated frequency, whether ancestry resolves, how hard the
/// over-fetch loop is working.
///
/// It shows blocked items, their reasons, and the rule that fired. **None of
/// that may ever appear on the kid's side**, which is exactly why it now lives
/// behind the passcode.
struct SearchView: View {
    @Bindable var session: Session

    @State private var term = ""
    @State private var results: KindedResults?
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        List {
                if let results {
                    allowedSection(results)
                    blockedSection(results)
                    diagnosticsSection(results)
                }
            }
            .navigationTitle("Diagnostics")
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

    // MARK: - Sections

    private func allowedSection(_ results: KindedResults) -> some View {
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
                Group {
                    // Only songs are tappable. This screen has no browse stack
                    // to push an album or artist onto, and handing a container
                    // to the player would surface an error alert for what is
                    // really just a row with nowhere to go.
                    if item.id.kind == .song {
                        Button { play(item) } label: { row(item) }
                    } else {
                        row(item)
                    }
                }
                // Both gestures, because a swipe is not discoverable and this
                // is the control that tests the safety-critical case.
                .swipeActions(edge: .trailing) { denyButtons(for: item) }
                .contextMenu { denyButtons(for: item) }
            }
        }
    }

    private func blockedSection(_ results: KindedResults) -> some View {
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

    private func diagnosticsSection(_ results: KindedResults) -> some View {
        Section("Diagnostics") {
            LabeledContent("Requests", value: "\(results.requestCount)")
            LabeledContent("Reached end", value: results.reachedEnd ? "yes" : "no")
            LabeledContent("Gave up early", value: results.gaveUpEarly ? "yes" : "no")
            // Per kind, because a search is now one over-fetch loop per kind and
            // a single total hides which one is struggling.
            ForEach(KindedResults.displayOrder, id: \.self) { kind in
                if let kinded = results.results(for: kind) {
                    LabeledContent(
                        kind.rawValue.capitalized,
                        value: "\(kinded.items.count) shown, \(kinded.blocked.count) blocked"
                            + (kinded.gaveUpEarly ? " — gave up" : "")
                    )
                }
            }
            // Research question 1: how often is contentRating nil? This is the
            // cheap version of Tools/RatingProbe, and the number it shows
            // decides the UnratedBehavior default and whether an over-fetch
            // multiplier of 3 is anywhere near right.
            LabeledContent("Unrated seen", value: unrated(results))
            // Whether ancestry actually resolved. MusicKit logs "A
            // MusicIdentifierSet with empty string … is being used" freely, and
            // that log cannot distinguish harmless noise from lineage silently
            // failing to arrive. These two counts can: a deny on an artist only
            // reaches their tracks if the artist count matches the result
            // count.
            LabeledContent("With album", value: lineage(results, .album))
            LabeledContent("With artist", value: lineage(results, .artist))
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
    /// There is still no button for widening a *song* to its album. A song's
    /// `CatalogItem` carries the artist name as its subtitle but never the
    /// album's title, and `displayName` is copied at write time and never
    /// refreshed — so an album deny taken from a song row would store a
    /// permanently wrong name.
    ///
    /// Denying an album row itself is fine, and now possible: an album result
    /// carries its own correct title. Hence the kind-named button rather than a
    /// hardcoded "Deny song", which would have quietly mislabelled every album
    /// and artist row as soon as those started coming back.
    @ViewBuilder
    private func denyButtons(for item: CatalogItem) -> some View {
        if let artist = item.ancestors.first(where: { $0.id.kind == .artist }) {
            Button("Deny artist", role: .destructive) {
                deny(artist.id, name: item.subtitle ?? "Artist")
            }
        }
        Button("Deny \(item.id.kind.rawValue)", role: .destructive) {
            deny(item.id, name: item.title, artwork: item.artworkURL)
        }
    }

    private func row(_ item: CatalogItem) -> some View {
        VStack(alignment: .leading) {
            Text(item.title)
            Text(subtitle(for: item)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The kind leads, because results are mixed now and an album and a song of
    /// the same name are otherwise the same row twice.
    private func subtitle(for item: CatalogItem) -> String {
        var parts = [item.id.kind.rawValue]
        if let subtitle = item.subtitle { parts.append(subtitle) }
        return parts.joined(separator: " · ")
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

    private func judged(_ results: KindedResults) -> [CatalogItem] {
        results.items + results.blocked.map(\.item)
    }

    /// How many rateable results came back with no rating, over how many were
    /// rateable at all.
    ///
    /// **Artists are excluded from both halves.** MusicKit's `Artist` has no
    /// `contentRating` at all, so every artist result is `nil` by construction —
    /// counting them would answer research question 1 with a number made
    /// entirely of items the question is not about, and six artists a search
    /// would have made unrated content look far more common than it is. That
    /// distortion arrived the moment search stopped being song-only, which is
    /// why the denominator is now shown rather than implied.
    private func unrated(_ results: KindedResults) -> String {
        let rateable = judged(results).filter { $0.id.kind == .song || $0.id.kind == .album }
        return "\(rateable.filter { $0.rating == nil }.count) / \(rateable.count)"
    }

    /// How many results that *can* have an ancestor of this kind actually carry
    /// a non-empty one.
    ///
    /// The denominator counts only the kinds for which the ancestor is possible:
    /// a song has both an album and an artist, an album has an artist and no
    /// album, and an artist has neither. Counting every result would make
    /// ancestry resolution look broken as soon as artists appear in results,
    /// when nothing had changed about whether lineage resolves. Open question 13
    /// is answered by this number, so its denominator has to be honest.
    private func lineage(_ results: KindedResults, _ ancestor: ItemKind) -> String {
        let eligible = judged(results).filter { item in
            switch (item.id.kind, ancestor) {
            case (.song, _): true
            case (.album, .artist): true
            default: false
            }
        }
        let resolved = eligible.filter { item in
            item.ancestors.contains { $0.id.kind == ancestor && !$0.id.rawValue.isEmpty }
        }
        return "\(resolved.count) / \(eligible.count)"
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
