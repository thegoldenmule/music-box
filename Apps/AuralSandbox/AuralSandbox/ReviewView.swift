import FamilyStore
import PolicyEngine
import SwiftUI

/// What a parent reads. **The one screen in the app that hides nothing.**
///
/// Everywhere else a denied item vanishes, because a tile a kid can see and
/// cannot play is an invitation to ask why. Here a denied item is the point: the
/// engine is consulted to annotate a row rather than to remove it, and every
/// read behind this screen comes through a seam that has no filtering variant.
///
/// Organised by question rather than by table — three event tables and a library
/// are four things a parent does not care about. The whole record is one step
/// behind, not the front door, because a level 2 kid generates a block row per
/// filtered result per search and a reverse-chronological wall of them reads as
/// a list of things their child tried to reach.
struct ReviewView: View {
    @Bindable var session: Session
    @State private var model: ReviewModel

    init(session: Session, kid: Kid) {
        self.session = session
        _model = State(initialValue: ReviewModel(session: session, kid: kid))
    }

    var body: some View {
        Form {
            kidSection
            noticesSection
            summarySection
            questionsSection
            wholeRecordSection
            deleteSection
        }
        .navigationTitle("\(model.kid.name)'s activity")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Range", selection: $model.range) {
                    ForEach(ReviewRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
        .refreshable { await model.load() }
        .task { if model.window == nil { await model.load() } }
        .alert(
            "Couldn't do that",
            isPresented: Binding(
                get: { model.failure != nil },
                set: { if !$0 { model.clearFailure() } }
            ),
            actions: { Button("OK") { model.clearFailure() } },
            message: { Text(model.failure ?? "") }
        )
        .onAppear { session.touchAdmin() }
    }

    // MARK: - Which kid

    /// Choosing a kid here does **not** switch the active kid. Reading a report
    /// must never change what a child's device is showing them, and on a shared
    /// device the normal case is reviewing one child while another is mid-song.
    @ViewBuilder
    private var kidSection: some View {
        if session.kids.count > 1 {
            Section {
                Picker("Child", selection: kidBinding) {
                    ForEach(session.kids, id: \.id) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("Reading this does not change who is using the app.")
            }
        }
    }

    private var kidBinding: Binding<UUID> {
        Binding(
            get: { model.kid.id },
            set: { id in
                if let kid = session.kids.first(where: { $0.id == id }) { model.show(kid) }
            }
        )
    }

    // MARK: - What this screen is not

    private var noticesSection: some View {
        Section {
            if model.isLoading && model.window == nil {
                HStack {
                    ProgressView()
                    Text("Reading…").foregroundStyle(.secondary)
                }
            }

            if let window = model.window {
                LabeledContent("As of", value: window.builtAt.formatted(date: .omitted, time: .shortened))

                // A swept week and a quiet week are different claims, and an
                // empty list can only make one of them.
                if case .summarisedBefore(let date) = window.coverage {
                    Label(
                        "Only summaries before \(date.formatted(date: .abbreviated, time: .omitted)). The detail was cleared.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .foregroundStyle(.secondary)
                }

                // A silent zero and a silent forty look identical, and one of
                // them is a bug in us.
                if window.unreadable > 0 {
                    Label(
                        "\(window.unreadable) row\(window.unreadable == 1 ? "" : "s") couldn't be read back.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - The week

    @ViewBuilder
    private var summarySection: some View {
        if let summary = model.summary {
            Section(model.range.label) {
                LabeledContent("Listening", value: ReviewFormat.duration(summary.totalListeningSeconds))
                LabeledContent("Searches", value: "\(summary.searchCount)")
                LabeledContent("Reached for something blocked", value: "\(summary.reachedBlockCount)")
            }
        }
    }

    // MARK: - The four questions

    @ViewBuilder
    private var questionsSection: some View {
        if let window = model.window {
            Section {
                NavigationLink {
                    ReviewPlaysView(model: model)
                } label: {
                    row("What they listened to", "\(window.plays.count)", "play.circle")
                }

                NavigationLink {
                    ReviewSearchesView(model: model)
                } label: {
                    row("What they went looking for", "\(window.searches.count)", "magnifyingglass")
                }

                NavigationLink {
                    ReviewVisitsView(model: model)
                } label: {
                    row("Where they went", "\(window.visits.count)", "signpost.right")
                }

                NavigationLink {
                    ReviewBlocksView(model: model)
                } label: {
                    // Two numbers, never one. The reached count is about the
                    // child; the rest is about our filter.
                    row(
                        "What they couldn't reach",
                        blockCaption,
                        "hand.raised"
                    )
                }

                NavigationLink {
                    ReviewLibraryView(model: model)
                } label: {
                    row("What they kept", libraryCaption, "heart")
                }
            }
        }
    }

    private var blockCaption: String {
        let reached = model.blocks.filter { $0.fact.event.reach == .reached }.count
        let unseen = model.blocks.count - reached
        if unseen == 0 { return "\(reached)" }
        return "\(reached) reached · \(unseen) unseen"
    }

    private var libraryCaption: String {
        guard let library = model.library else { return "" }
        let blocked = library.blockedFavorites.count
        let base = "\(library.favorites.count) · \(library.playlists.count) playlist\(library.playlists.count == 1 ? "" : "s")"
        return blocked == 0 ? base : "\(base) · \(blocked) blocked"
    }

    private func row(_ title: String, _ caption: String, _ symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - The whole record

    private var wholeRecordSection: some View {
        Section {
            NavigationLink("The whole record") { ReviewLogView(model: model) }
        }
    }

    // MARK: - Delete

    @State private var confirmingHistory = false
    @State private var confirmingEverything = false

    private var deleteSection: some View {
        Section {
            Button("Clear \(model.kid.name)'s logs", role: .destructive) {
                confirmingHistory = true
            }
            Button("Delete everything \(model.kid.name) did", role: .destructive) {
                confirmingEverything = true
            }
        } header: {
            Text("Delete")
        } footer: {
            Text(
                "Clearing the logs removes searches, plays and blocks, and the weekly summaries made from them. Their favorites and playlists are their own work and are only removed by the second one."
            )
        }
        .confirmationDialog(
            "Clear the logs?",
            isPresented: $confirmingHistory,
            titleVisibility: .visible
        ) {
            Button("Clear logs", role: .destructive) { model.deleteHistory() }
        } message: {
            Text("Searches, plays, blocks and summaries. Favorites and playlists stay.")
        }
        .confirmationDialog(
            "Delete everything?",
            isPresented: $confirmingEverything,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { model.deleteEverything() }
        } message: {
            Text(
                "The logs, and every favorite and playlist \(model.kid.name) made. Their playlists cannot be recovered. Your allow and deny lists are not touched."
            )
        }
    }
}

// MARK: - Saying it in a parent's words

enum ReviewFormat {
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Why something was blocked, at the time.
    ///
    /// `restrictedOutsideApp` is never phrased as one of the parent's own rules.
    /// Screen Time and Apple Music's controls refuse things for reasons that
    /// have nothing to do with a list they wrote.
    static func reason(_ reason: BlockReason, deniedBy: PolicyEntrySnapshot?) -> String {
        switch reason {
        case .notOnAllowList:
            "Not on your list"
        case .deniedByParent:
            deniedBy.map { "You denied \($0.displayName)" } ?? "A rule you have since removed"
        case .explicitContent:
            "Marked explicit"
        case .unrated:
            "No rating available"
        case .restrictedOutsideApp:
            "Blocked outside this app — Screen Time or Apple Music"
        }
    }

    /// Where a row came from, as a sentence fragment.
    static func origin(_ description: OriginDescription) -> String {
        switch description {
        case .home:
            "from the home screen"
        case .search(let term):
            "while searching for “\(term)”"
        case .browse(let id, let name):
            name.map { "while looking at \($0)" } ?? "while looking at \(article(id.kind))"
        case .catalogPlaylist(_, let name):
            name.map { "from the playlist \($0)" } ?? "from a playlist"
        case .kidPlaylist(_, let name):
            name.map { "from their playlist \($0)" } ?? "from a playlist they have since deleted"
        case .suggestion:
            "from what you suggested"
        case .suggestedPlaylist(_, let name):
            name.map { "from the playlist you suggested, \($0)" }
                ?? "from a playlist you suggested and have since taken back"
        case .unknown:
            "from somewhere we can no longer read"
        }
    }

    private static func article(_ kind: ItemKind) -> String {
        switch kind {
        case .album: "an album"
        case .artist: "an artist"
        case .playlist: "a playlist"
        case .song: "a song"
        }
    }

    /// Today's verdict, hedged exactly as far as the evidence allows.
    ///
    /// Three states and never two: `nil` means the input that would decide is
    /// missing, and rendering that as "blocked" would show a parent our own gap
    /// dressed up as a fact about their child's music.
    static func standing<Fact>(_ annotated: Annotated<Fact>) -> (text: String, isWarning: Bool)? {
        switch annotated.confidence {
        case .unknown:
            return ("Can't tell without checking the catalog", false)
        case .exact, .itemOnly:
            guard let verdict = annotated.now else { return nil }
            let hedge = annotated.confidence == .itemOnly ? "Probably " : ""
            switch verdict {
            case .allowed:
                return nil
            case .blocked(let reason):
                let why = ReviewFormat.reason(BlockReason(reason), deniedBy: nil)
                return ("\(hedge)can't play this now — \(why.lowercasedFirst)", true)
            }
        }
    }
}

extension String {
    fileprivate var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
