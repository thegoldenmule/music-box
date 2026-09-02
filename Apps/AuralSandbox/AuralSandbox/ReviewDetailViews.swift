import FamilyStore
import KidLibrary
import PolicyEngine
import SwiftUI

// The four questions, and the record behind them. Every list here is unfiltered
// — see ``ReviewView``.

// MARK: - What they listened to

struct ReviewPlaysView: View {
    let model: ReviewModel

    var body: some View {
        List {
            if let summary = model.summary {
                if !summary.topArtists.isEmpty {
                    Section("Most listened to") {
                        ForEach(summary.topArtists) { tally in
                            LabeledContent(
                                model.names[CatalogID(.artist, tally.id)] ?? tally.name,
                                value: ReviewFormat.duration(tally.seconds)
                            )
                        }
                    }
                }

                if !summary.topSongs.isEmpty {
                    Section("Played most often") {
                        ForEach(summary.topSongs) { tally in
                            LabeledContent(
                                tally.name,
                                value: "\(tally.plays)×"
                            )
                        }
                    }
                }

                if !summary.firstTimeHeard.isEmpty {
                    Section {
                        ForEach(summary.firstTimeHeard) { Text($0.name) }
                    } header: {
                        Text("Heard for the first time")
                    } footer: {
                        Text("As far back as we looked. A very long history is only read in part.")
                    }
                }
            }

            Section("Every play") {
                if model.plays.isEmpty {
                    Text("Nothing played in this period.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.plays.enumerated()), id: \.offset) { _, play in
                    ReviewPlayRow(model: model, play: play)
                }
            }
        }
        .navigationTitle("Listened to")
    }
}

private struct ReviewPlayRow: View {
    let model: ReviewModel
    let play: Annotated<PlayEvent>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(play.fact.displayName)
            Text(
                "\(ReviewFormat.duration(play.fact.secondsPlayed)) · \(ReviewFormat.origin(model.described(play.fact.origin)))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(play.fact.at.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
            // The disagreement between then and now is the useful part: they
            // listened to this on Tuesday and you denied the artist on Friday.
            if let standing = ReviewFormat.standing(play) {
                Text(standing.text)
                    .font(.caption)
                    .foregroundStyle(standing.isWarning ? .orange : .secondary)
            }
        }
    }
}

// MARK: - What they went looking for

struct ReviewSearchesView: View {
    let model: ReviewModel

    var body: some View {
        List {
            if model.window?.searches.isEmpty ?? true {
                Text("No searches in this period.").foregroundStyle(.secondary)
            }
            ForEach(Array((model.window?.searches ?? []).enumerated()), id: \.offset) { _, search in
                VStack(alignment: .leading, spacing: 3) {
                    // Verbatim, as they typed it. Never normalised, corrected or
                    // tidied — this is the most sensitive thing in the store and
                    // the least useful to paraphrase.
                    Text(search.term)
                    Text(outcome(search))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(search.at.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Went looking for")
    }

    /// `gaveUpEarly` is the difference between *nothing matched* and *we stopped
    /// looking*, and the column exists so this line can be honest about which.
    private func outcome(_ search: SearchEvent) -> String {
        var parts = ["\(search.resultCount) shown"]
        if search.blockedCount > 0 { parts.append("\(search.blockedCount) filtered out") }
        if search.gaveUpEarly {
            parts.append(
                search.resultCount == 0
                    ? "we stopped looking before finding anything"
                    : "we stopped looking early"
            )
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Where they went

/// Every arrival, in order.
///
/// The Recent shelf is a projection over exactly these rows, collapsed so that
/// only the deepest thing in each excursion survives. This is the record the
/// shelf was made from: a parent reading it sees the artist their kid opened
/// *and* the album they went into next, which the shelf deliberately does not
/// show them.
struct ReviewVisitsView: View {
    let model: ReviewModel

    var body: some View {
        List {
            if model.window?.visits.isEmpty ?? true {
                Text("Nothing opened in this period.").foregroundStyle(.secondary)
            }
            ForEach(Array((model.window?.visits ?? []).enumerated()), id: \.offset) { _, visit in
                VStack(alignment: .leading, spacing: 3) {
                    Text(visit.displayName)
                    Text(caption(visit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(visit.at.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Where they went")
    }

    private func caption(_ visit: VisitEvent) -> String {
        let verb = visit.manner == .played ? "played" : "opened"
        return "\(verb) · \(visit.itemID.kind.rawValue)"
    }
}

// MARK: - What they couldn't reach

struct ReviewBlocksView: View {
    let model: ReviewModel

    var body: some View {
        List {
            if model.groups.isEmpty {
                Text("Nothing was blocked in this period.").foregroundStyle(.secondary)
            }
            ForEach(model.groups) { group in
                NavigationLink {
                    ReviewBlockGroupView(model: model, group: group)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title(of: group))
                        Text(counts(group))
                            .font(.caption)
                            .foregroundStyle(group.reached > 0 ? .primary : .secondary)
                    }
                }
            }
        }
        .navigationTitle("Couldn't reach")
    }

    /// **Never one number.** The unseen count is a fact about our filter — the
    /// over-fetch loop discards a multiple of every page — and summing the two
    /// would report our own machinery as things a child went after.
    private func counts(_ group: BlockGroup) -> String {
        switch (group.reached, group.unseen) {
        case (0, let unseen):
            return "\(unseen) filtered out before they saw them"
        case (let reached, 0):
            return "reached for \(reached)"
        case (let reached, let unseen):
            return "reached for \(reached) · \(unseen) they never saw"
        }
    }
}

struct ReviewBlockGroupView: View {
    let model: ReviewModel
    let group: BlockGroup

    var body: some View {
        List {
            Section {
                if group.reached > 0 {
                    Label(
                        "They reached for \(group.reached) of these — tapped play, or tried to keep one.",
                        systemImage: "hand.tap"
                    )
                }
                if group.unseen > 0 {
                    Label(
                        "\(group.unseen) never appeared on their screen. We filtered them out of results.",
                        systemImage: "eye.slash"
                    )
                    .foregroundStyle(.secondary)
                }
                Text(ReviewFormat.origin(model.described(group.sample.origin)).capitalizedFirst)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Allow this") {
                Button("Allow “\(group.sample.displayName)”") {
                    model.add(
                        .allow,
                        id: group.sample.itemID,
                        displayName: group.sample.displayName
                    )
                }
                // Offered only when the lineage actually resolved. Widening to
                // an artist we never identified would be guessing at which one.
                if let artistID = group.artistID {
                    Button("Allow everything by \(model.title(of: group))") {
                        model.add(.allow, id: artistID, displayName: model.title(of: group))
                    }
                    Button("Deny everything by \(model.title(of: group))", role: .destructive) {
                        model.add(.deny, id: artistID, displayName: model.title(of: group))
                    }
                }
            }

            Section {
                ForEach(rows, id: \.0) { _, block in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.fact.event.displayName)
                        Text(
                            ReviewFormat.reason(
                                block.fact.event.reason,
                                deniedBy: block.fact.deniedBy
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(
                            "\(block.fact.event.reach == .reached ? "Reached for" : "Never seen") · \(block.fact.event.at.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Every one")
            } footer: {
                Text(
                    "Allowing something does not change what already happened. These keep the reason that blocked them at the time."
                )
            }
        }
        .navigationTitle(model.title(of: group))
    }

    /// This group's rows, reached-for first.
    private var rows: [(Int, Annotated<ReviewedBlock>)] {
        model.blocks
            .filter { block in
                if let artistID = group.artistID { return block.fact.event.artistID == artistID }
                return block.fact.event.artistID == nil
                    && block.fact.event.displayName == group.displayName
            }
            .sorted { ($0.fact.event.reach == .reached ? 1 : 0) > ($1.fact.event.reach == .reached ? 1 : 0) }
            .enumerated()
            .map { ($0.offset, $0.element) }
    }
}

// MARK: - What they kept

struct ReviewLibraryView: View {
    let model: ReviewModel

    var body: some View {
        List {
            if let library = model.library {
                providerSection(library)

                Section {
                    if library.favorites.isEmpty {
                        Text("Nothing favorited yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(library.favorites.enumerated()), id: \.offset) { _, favorite in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(favorite.fact.displayName)
                            Text(caption(favorite))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let standing = ReviewFormat.standing(favorite) {
                                Text(standing.text)
                                    .font(.caption)
                                    .foregroundStyle(standing.isWarning ? .orange : .secondary)
                            }
                        }
                    }
                } header: {
                    Text("Favorites")
                } footer: {
                    // The row survives and the tile does not. A parent learning
                    // that here is the point of the screen.
                    Text(
                        "Anything you have denied since is still on this list and gone from their screens."
                    )
                }

                Section("Playlists") {
                    if library.playlists.isEmpty {
                        Text("No playlists yet.").foregroundStyle(.secondary)
                    }
                    ForEach(library.playlists) { playlist in
                        NavigationLink {
                            ReviewPlaylistView(playlist: playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                Text(caption(playlist))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                HStack {
                    ProgressView()
                    Text("Reading their shelf…").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("What they kept")
    }

    /// A short shelf because a provider failed and a short shelf because the kid
    /// kept little look identical, and only one of them is about the child.
    @ViewBuilder
    private func providerSection(_ library: ReviewedLibrary) -> some View {
        let notable = library.providers.filter { $0.value != .live }
        if !notable.isEmpty || !library.isResolved || library.unresolved > 0 {
            Section {
                ForEach(Array(notable.keys), id: \.self) { id in
                    if let health = notable[id] {
                        Label(describe(id, health), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if !library.isResolved {
                    Label(
                        "Apple Music didn't answer, so these are judged on what we stored.",
                        systemImage: "wifi.slash"
                    )
                    .foregroundStyle(.secondary)
                }
                if library.unresolved > 0 {
                    Label(
                        "\(library.unresolved) item\(library.unresolved == 1 ? "" : "s") couldn't be looked up.",
                        systemImage: "questionmark.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Where this came from")
            }
        }
    }

    private func describe(_ id: LibraryProviderID, _ health: ProviderHealth) -> String {
        let name = id == .cloudKit ? "This app's own store" : "The Apple Music library"
        switch health {
        case .live:
            return "\(name): in use"
        case .notConfigured(.sharedDevice):
            return "\(name) is not read — you said this device is shared."
        case .notConfigured(.notYetAsked):
            return "\(name) is not read — the setup question hasn't been answered."
        case .notConfigured(.grownUpMode):
            return "\(name) is set aside while a grown-up is listening."
        case .failed(let message):
            return "\(name) failed on this read: \(message)"
        }
    }

    private func caption(_ favorite: Annotated<FavoriteRow>) -> String {
        var parts = [favorite.fact.catalogID.kind.rawValue]
        // Which favorites they chose, and which arrived with the account. A
        // shelf that filled itself should not read as a very busy week.
        if favorite.fact.origin == .appleLibrary { parts.append("already in the library") }
        parts.append(favorite.fact.favoritedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private func caption(_ playlist: ReviewedPlaylist) -> String {
        var parts = ["\(playlist.entries.count) song\(playlist.entries.count == 1 ? "" : "s")"]
        if playlist.blockedCount > 0 { parts.append("\(playlist.blockedCount) they can't play") }
        if playlist.divergesFromApple { parts.append("edits don't reach Apple Music") }
        return parts.joined(separator: " · ")
    }
}

struct ReviewPlaylistView: View {
    let playlist: ReviewedPlaylist

    var body: some View {
        List {
            if playlist.divergesFromApple {
                Section {
                    Label(
                        "This playlist was not made in this app, so changes here don't reach the copy in Apple Music.",
                        systemImage: "arrow.triangle.branch"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Section {
                if playlist.entries.isEmpty {
                    Text("Empty.").foregroundStyle(.secondary)
                }
                ForEach(Array(playlist.entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.fact.displayName)
                        if let standing = ReviewFormat.standing(entry) {
                            Text(standing.text)
                                .font(.caption)
                                .foregroundStyle(standing.isWarning ? .orange : .secondary)
                        }
                    }
                }
            } footer: {
                Text("In the order they put them in.")
            }
        }
        .navigationTitle(playlist.name)
    }
}

// MARK: - The whole record

/// Everything, newest first — including the rows the grouped views compress.
///
/// It exists because the promise of this app is that a parent can see all of it,
/// and because a grouped view is our reading of the record rather than the
/// record. A parent should be able to check us.
struct ReviewLogView: View {
    let model: ReviewModel

    private enum Row: Identifiable {
        case play(Int, Annotated<PlayEvent>)
        case search(Int, SearchEvent)
        case block(Int, Annotated<ReviewedBlock>)
        case visit(Int, VisitEvent)

        var id: String {
            switch self {
            case .play(let i, _): "play-\(i)"
            case .search(let i, _): "search-\(i)"
            case .block(let i, _): "block-\(i)"
            case .visit(let i, _): "visit-\(i)"
            }
        }

        var at: Date {
            switch self {
            case .play(_, let play): play.fact.at
            case .search(_, let search): search.at
            case .block(_, let block): block.fact.event.at
            case .visit(_, let visit): visit.at
            }
        }
    }

    var body: some View {
        List(rows) { row in
            VStack(alignment: .leading, spacing: 3) {
                switch row {
                case .play(_, let play):
                    Label(play.fact.displayName, systemImage: "play.fill")
                    detail(
                        "Played \(ReviewFormat.duration(play.fact.secondsPlayed)) \(ReviewFormat.origin(model.described(play.fact.origin)))"
                    )
                case .search(_, let search):
                    Label(search.term, systemImage: "magnifyingglass")
                    detail("\(search.resultCount) shown, \(search.blockedCount) filtered out")
                case .block(_, let block):
                    Label(block.fact.event.displayName, systemImage: "hand.raised")
                    detail(
                        "\(block.fact.event.reach == .reached ? "Reached for" : "Never seen") · \(ReviewFormat.reason(block.fact.event.reason, deniedBy: block.fact.deniedBy))"
                    )
                case .visit(_, let visit):
                    Label(visit.displayName, systemImage: "signpost.right")
                    detail(
                        "\(visit.manner == .played ? "Played" : "Opened") · \(visit.itemID.kind.rawValue)"
                    )
                }
                Text(row.at.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("The whole record")
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private var rows: [Row] {
        var rows: [Row] = []
        for (index, play) in model.plays.enumerated() { rows.append(.play(index, play)) }
        for (index, search) in (model.window?.searches ?? []).enumerated() {
            rows.append(.search(index, search))
        }
        for (index, block) in model.blocks.enumerated() { rows.append(.block(index, block)) }
        for (index, visit) in (model.window?.visits ?? []).enumerated() {
            rows.append(.visit(index, visit))
        }
        return rows.sorted { $0.at > $1.at }
    }
}

extension String {
    fileprivate var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
