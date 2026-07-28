import CatalogKit
import FamilyStore
import SwiftUI

/// The kid's app. Big tiles, one job, no way out.
///
/// What is deliberately absent matters as much as what is here. No links out,
/// nothing about subscriptions or buying anything, no "more like this", no
/// blocked items shown as tappable-then-refusing, and **no search field at all
/// in level 1** — not present and empty, absent, because an empty search box is
/// an invitation to keep trying.
struct KidHomeView: View {
    @Bindable var session: Session
    @State private var player: KidPlayerModel

    @State private var recents: [CatalogItem] = []
    @State private var mine: [CatalogItem] = []
    @State private var term = ""
    @State private var search: SearchState = .home
    /// Held so a second search cancels the first. Without it the slower of two
    /// round trips wins whichever order they were asked for in, and the kid ends
    /// up looking at results for a term they have already replaced.
    @State private var searchTask: Task<Void, Never>?
    /// Artists, because it is the kind a search is most often for and the one
    /// that lands first — nothing is filtered out of an artist page, so it
    /// settles in a single request while songs are still paging.
    @State private var filter: SearchFilter = .artists
    @State private var isLoading = false
    @State private var trouble: String?
    @State private var showingAdmin = false
    /// Type-erased, because this stack pushes two unrelated things: a
    /// `CatalogItem` when browsing into a container, and a ``HomeRoute`` for the
    /// history. A `[CatalogItem]` path accepts only the former and refuses the
    /// latter at runtime — it compiles, and the link simply does not work.
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    init(session: Session) {
        self.session = session
        _player = State(initialValue: KidPlayerModel(session: session))
    }

    private var canSearch: Bool { session.kid.mode != .allowOnly }

    /// Whether the home screen is what is underneath — as opposed to a search,
    /// running or finished. Reloading recents out from under a set of results
    /// would swap the screen for one nobody asked for.
    private var isHome: Bool {
        if case .home = search { return true }
        return false
    }

    /// Everything currently tappable, which is what a play queues from.
    ///
    /// The *visible* results, not every result: a kid looking at Songs should
    /// get a queue of the songs they can see, not one silently padded out of a
    /// tab they are not on.
    private var shown: [CatalogItem] { visible ?? (recents + mine) }

    /// What the results grid is showing, once the filter has had its say.
    private var visible: [CatalogItem]? {
        guard case .results(let results) = search else { return nil }
        return results.items(of: filter.kind)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                // A crossfade on every branch, so the swap to the loader and the
                // swap from it to results are the same gesture rather than two
                // hard cuts a fast search turns into a flash.
                switch search {
                case .home:
                    home.transition(.opacity)
                case .running(let term):
                    SearchingView(term: term).transition(.opacity)
                case .results(let found):
                    results(found).transition(.opacity)
                case .trouble:
                    searchFailed.transition(.opacity)
                }
            }
            .navigationTitle(session.kid.name)
            .navigationDestination(for: CatalogItem.self) { container in
                BrowseView(session: session, player: player, container: container)
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .history:
                    HistoryView(session: session, player: player)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // The one route off this screen, and it is a locked door
                    // rather than a link: it opens the gate, not the admin.
                    Button {
                        showingAdmin = true
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { NowPlayingBar(session: session, player: player) }
        }
        .modifier(
            SearchIfAllowed(enabled: canSearch, term: $term, onSubmit: runSearch)
        )
        .sheet(isPresented: $showingAdmin, onDismiss: reload) {
            NavigationStack {
                if session.isAdminOpen {
                    AdminView(session: session) {
                        session.closeAdmin()
                        showingAdmin = false
                    }
                } else {
                    AdminGateView(session: session) {}
                }
            }
        }
        .task { reload() }
        .onChange(of: term) { _, new in
            if new.isEmpty {
                searchTask?.cancel()
                searchTask = nil
                filter = .artists
                withAnimation(.easeInOut(duration: 0.2)) { search = .home }
            }
        }
        // A play is written when the track ends, is skipped, or the app goes
        // away — duration is the signal, and there is no stop control. So
        // recents changes when what is playing changes, which is when to look
        // again.
        .onChange(of: player.current?.id) { _, _ in
            if isHome { reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Otherwise a kid who plays one song and puts the phone down never
            // produces a play event at all.
            if phase != .active {
                player.flush()
            } else if isHome {
                reload()
            }
        }
    }

    /// Search results: one kind at a time, with the tabs across the top.
    ///
    /// The tabs are fixed — always all three, in the same order, whatever came
    /// back. Hiding the ones that found nothing sounds kinder and is not: the
    /// kinds land at different times, so a tab would appear mid-search and shove
    /// the ones beside it out from under a finger already on the way down. Three
    /// tabs that never move, one of which may say "nothing to play", is the
    /// steadier thing to aim at.
    @ViewBuilder
    private func results(_ results: KindedResults) -> some View {
        let items = visible ?? []

        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(SearchFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            // Still coming is a different screen from came back empty, and the
            // two are only distinguishable because `KindedResults` keeps them
            // apart. Guessing here would show "nothing to play" over a search
            // that was about to find twenty-four things.
            if results.isPending(filter.kind) {
                Spacer()
                ProgressView()
                Spacer()
            } else if items.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label("Nothing to play", systemImage: "magnifyingglass")
                }
                Spacer()
            } else if filter == .songs {
                SongList(items: items) { item in
                    Task { await playSong(item) }
                }
            } else {
                TileGrid(items: items) { item in
                    Task { await playSong(item) }
                }
            }
        }
    }

    /// A search that did not come back.
    ///
    /// Plain words and a way to try again, in the tone of the one other message
    /// a kid is ever shown. No error text, no code, and nothing that reads as
    /// "you did something wrong" — the network fell over, which is not a thing a
    /// six-year-old can act on.
    private var searchFailed: some View {
        ContentUnavailableView {
            Label("That didn't work", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Let's try again.")
        } actions: {
            Button("Try again") { runSearch() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Recents first at every level, then whatever else this level offers.
    ///
    /// Recents on top even in level 1, where home used to be the allow list
    /// alone. It is safe there precisely because it is filtered at render time:
    /// a level 1 recent is something that was on the allow list when it played
    /// and still is now, so this is a shortcut into the allow list rather than a
    /// way around it.
    @ViewBuilder
    private var home: some View {
        if isLoading && recents.isEmpty && mine.isEmpty {
            ProgressView()
        } else if recents.isEmpty && mine.isEmpty {
            ContentUnavailableView {
                Label(
                    session.kid.mode == .allowOnly
                        ? "Nothing here yet"
                        : "Pick something to listen to",
                    systemImage: "music.note.list"
                )
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !recents.isEmpty {
                        Section {
                            RecentRow(items: recents) { item in
                                Task { await playSong(item) }
                            }
                        } header: {
                            NavigationLink(value: HomeRoute.history) {
                                HStack {
                                    Text("Recent").font(.title2.bold())
                                    Image(systemName: "chevron.right")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !mine.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Yours").font(.title2.bold()).padding(.horizontal)
                            TileWrap(items: mine) { item in
                                Task { await playSong(item) }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }

    // MARK: - Loading

    private func reload() {
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                recents = try await session.homeItems()
                mine = session.kid.mode == .allowOnly
                    ? try await session.allowListItems()
                    : []
            } catch {
                trouble = Session.message(for: error)
            }
        }
    }

    /// Leaves for the search screen on the keystroke, not on the response.
    ///
    /// The state change is synchronous and the round trip happens behind it.
    /// Doing it the other way around — waiting, then swapping — leaves a kid
    /// staring at the home screen they just typed away from for as long as the
    /// network takes, which reads as enter not working and gets hit again.
    private func runSearch() {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSearch, !term.isEmpty else { return }

        // Back to Artists on every new search, so two terms in a row start the
        // same way rather than the second landing on whichever tab the first
        // was left on.
        filter = .artists
        withAnimation(.easeInOut(duration: 0.2)) { search = .running(term) }

        searchTask?.cancel()
        searchTask = Task {
            do {
                // Filtered, and the blocked half still reaches the parent's
                // report even though the kid never sees it.
                for try await found in session.searchIncrementally(term: term) {
                    // A cancelled search has already been replaced on screen by
                    // the one that cancelled it. Its results are stale by
                    // definition.
                    guard !Task.isCancelled else { return }
                    // The opening snapshot carries nothing but the list of kinds
                    // still coming. Leaving the searching screen on it would
                    // trade one honest wait for a bar of three tabs and a
                    // spinner, so hold until a kind has actually landed.
                    guard !found.byKind.isEmpty else { continue }

                    withAnimation(.easeInOut(duration: 0.2)) {
                        search = .results(found)
                        retargetFilter(found)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                trouble = Session.message(for: error)
                withAnimation(.easeInOut(duration: 0.2)) { search = .trouble }
            }
        }
    }

    /// Move off a tab that has settled and has nothing on it.
    ///
    /// Artists is the right thing to open on and the wrong thing to be stuck on:
    /// plenty of terms match a song and no artist, and leaving the kid staring
    /// at "nothing to play" while twenty-four songs sit one tab over reads as
    /// the search having failed.
    ///
    /// Only once the tab in question has come back — moving off a kind that is
    /// merely still loading would jump away from results that are on their way.
    private func retargetFilter(_ results: KindedResults) {
        guard !results.isPending(filter.kind), results.items(of: filter.kind).isEmpty else {
            return
        }
        guard let populated = results.populatedKinds.first,
              let replacement = SearchFilter(kind: populated)
        else { return }
        filter = replacement
    }

    /// Songs play. Containers navigate, which ``TileGrid`` handles itself.
    private func playSong(_ item: CatalogItem) async {
        let origin: PlaybackOrigin = isHome ? .home : .search(term: term)
        await player.play(item, from: shown.filter { $0.id.kind == .song }, origin: origin)
    }
}

/// What the kid's home screen is showing.
///
/// ``running`` is a state rather than a flag beside the results because it is a
/// different screen, not the same screen with a spinner on it — and because it
/// carries the term it is looking for, which is the one thing worth saying while
/// there is nothing to show.
private enum SearchState {
    case home
    case running(String)
    case results(KindedResults)
    /// The lookup failed. Carries no reason, deliberately: nothing on the kid's
    /// side shows an error string, so a payload here could only ever be read by
    /// something that should not be showing it.
    case trouble
}

/// `searchable` applied only when the kid's level has search at all.
///
/// A modifier rather than an `if` around the view: toggling `searchable` in a
/// branch rebuilds the navigation stack underneath it.
private struct SearchIfAllowed: ViewModifier {
    let enabled: Bool
    @Binding var term: String
    let onSubmit: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $term, prompt: "What do you want to hear?")
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}

/// Which kind of result the search screen is showing.
///
/// One kind at a time, always. There is no "all" — mixing them meant inventing a
/// cross-kind ranking out of nothing, because Apple ranks within a type and
/// hands back no score that compares one type to another. A tab per kind asks no
/// such question.
///
/// A filter over results already in hand, **not a new search**. One search
/// fetches every kind, so switching costs nothing and the parent's report
/// records one search rather than one per tap.
///
/// A separate type from `ItemKind` because `ItemKind` has a `playlist` case the
/// kid's search deliberately never asks for, and because the order of these
/// cases is the order of the tabs.
enum SearchFilter: Hashable, Identifiable, CaseIterable {
    case artists
    case songs
    case albums

    var id: Self { self }

    var label: String {
        switch self {
        case .artists: "Artists"
        case .songs: "Songs"
        case .albums: "Albums"
        }
    }

    var kind: ItemKind {
        switch self {
        case .artists: .artist
        case .songs: .song
        case .albums: .album
        }
    }

    init?(kind: ItemKind) {
        switch kind {
        case .artist: self = .artists
        case .song: self = .songs
        case .album: self = .albums
        case .playlist: return nil
        }
    }
}

/// Where the home screen can go. A `CatalogItem` push is browsing; this is not.
enum HomeRoute: Hashable {
    case history
}

/// Recents, sideways. One row, scrolled horizontally, so it never pushes the
/// rest of the home screen off the bottom no matter how much a kid listens to.
struct RecentRow: View {
    let items: [CatalogItem]
    let onPlay: (CatalogItem) -> Void

    /// A grid column has a width and hands it to the tile. An `HStack` does
    /// not: the tile sizes to its content, so a long song title stretches the
    /// tile instead of wrapping inside it, and one tile fills the screen.
    private let tileWidth: CGFloat = 150

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    Group {
                        if item.id.kind == .song {
                            Button { onPlay(item) } label: { Tile(item: item) }
                        } else {
                            NavigationLink(value: item) { Tile(item: item) }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: tileWidth)
                }
            }
            .padding(.horizontal)
        }
        // Tall enough for artwork at this width plus two lines of title and one
        // of subtitle, so a long name does not crop the artwork above it.
        .frame(height: tileWidth + 76)
    }
}

/// A wrapping grid that does not scroll — for use inside a page that already
/// does. Nesting two scroll views breaks the outer one's gestures.
struct TileWrap: View {
    let items: [CatalogItem]
    let onPlay: (CatalogItem) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
            ForEach(items, id: \.id) { item in
                if item.id.kind == .song {
                    Button { onPlay(item) } label: { Tile(item: item) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: item) { Tile(item: item) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
    }
}

/// Big, square, tappable. Sized for a finger that is not very accurate yet.
struct TileGrid: View {
    let items: [CatalogItem]
    let onPlay: (CatalogItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    // A song is a play; a container is a push. Deciding that
                    // here rather than in a tap handler means the navigation
                    // destination is the enclosing stack's, so browsing nests
                    // without every screen owning a path.
                    if item.id.kind == .song {
                        Button { onPlay(item) } label: { Tile(item: item) }
                            .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: item) { Tile(item: item) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }
}

/// Songs, stacked.
///
/// A grid is for choosing between pictures. A song is a line of text with a
/// picture beside it — the artwork is recognition, not the thing being chosen —
/// so a 150pt square of it buys nothing a 56pt one does not, and costs most of
/// the screen. Four tiles fit a phone; eight rows do, and a kid hunting for the
/// one song they meant is reading titles.
///
/// Artists and albums stay as tiles, where the artwork genuinely is what is
/// being picked between.
/// The `footer` slot exists for the history screen, which pages: it puts a
/// spinner below the last row that loads the next page when it scrolls into
/// view. That has to live inside this scroll view, not below it, so the list
/// owns the scrolling and lends out the bottom.
struct SongList<Footer: View>: View {
    let items: [CatalogItem]
    let onPlay: (CatalogItem) -> Void
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Indexed, so the separator is decided by position rather than
                // by comparing against the last item's identifier. That
                // comparison drops the rule under any row that happens to share
                // an id with the last one — which is only ever the case when
                // something upstream has leaked a duplicate, but it turns one
                // bug into two and hides the shape of the first.
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        // Inset past the artwork, so the rule reads as a break
                        // between titles rather than a line across the page.
                        Divider().padding(.leading, SongRow.textInset)
                    }
                    Button { onPlay(item) } label: { SongRow(item: item) }
                        .buttonStyle(.plain)
                }
            }
            footer()
        }
    }
}

extension SongList where Footer == EmptyView {
    init(items: [CatalogItem], onPlay: @escaping (CatalogItem) -> Void) {
        self.init(items: items, onPlay: onPlay, footer: { EmptyView() })
    }
}

/// One song: artwork, what it is, and the play button at the end.
struct SongRow: View {
    let item: CatalogItem

    private static let artworkSize: CGFloat = 56
    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 12

    /// Where the text starts, which is where a separator should too.
    static var textInset: CGFloat { margin + artworkSize + gap }

    var body: some View {
        HStack(spacing: Self.gap) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                // Two lines, not truncated to one. Rows in a list are allowed
                // to differ in height — the grid's alignment problem does not
                // exist here — and cutting off the title of the thing being
                // chosen is the worse trade.
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Self.gap)
            // At the end of the row, never on the artwork — the same rule the
            // tiles follow. Clipping is ours to do; compositing onto Apple's
            // pixels is not. See `Tile.artwork`.
            Image(systemName: "play.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 10)
        // The whole row, including the gap the Spacer opens up, not just the
        // parts with something drawn on them.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text("Plays"))
    }

    private var artwork: some View {
        AsyncImage(url: item.artworkURL) { image in
            image.resizable().aspectRatio(1, contentMode: .fit)
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").foregroundStyle(.tertiary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct Tile: View {
    let item: CatalogItem

    /// Songs play where they stand; everything else opens. That is the only
    /// distinction a kid needs from a tile, and it is the one the tile draws.
    ///
    /// Deliberately the *action*, not the taxonomy. `TileGrid` already branches
    /// on exactly this to decide between a `Button` and a `NavigationLink`, so
    /// the look and the behaviour cannot drift apart.
    private var opens: Bool { item.id.kind != .song }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
            titleRow
            subtitleRow
        }
        // Padded whatever the kind, so every tile is the same size and a grid
        // of mixed kinds still lines up. Only the fill behind it differs.
        .padding(8)
        .background {
            if opens {
                RoundedRectangle(cornerRadius: 16).fill(.quaternary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        // Shape and glyph are invisible to VoiceOver, which otherwise announces
        // an album and a song of the same name identically.
        .accessibilityHint(Text(opens ? "Opens" : "Plays"))
    }

    /// **Clipped to a shape, never covered or composited onto.**
    ///
    /// The Developer Program License Agreement §3.3.6(D) says MusicKit Content
    /// may not be *modified*, and does not define the word. Clipping is the
    /// reading of that word this app has settled on: the shape of the frame is
    /// ours, what the frame contains is untouched, and nothing is ever drawn
    /// over the top. A circle crops harder than a rounded rectangle, so it is
    /// further along the same line rather than across a new one — and it is what
    /// the Music app itself does for artists, which is the convention a kid will
    /// have met everywhere else.
    ///
    /// Bytes are referenced by URL and never copied into our storage, which the
    /// same clause forbids outright.
    private var artwork: some View {
        AsyncImage(url: item.artworkURL) { image in
            image.resizable().aspectRatio(1, contentMode: .fit)
        } placeholder: {
            // A steady sight, not a flicker on the way to artwork: plenty of
            // artists have no image in the catalog at all, so this is what their
            // tile looks like for good. A glyph reads as "a person" where a bare
            // grey slab reads as something still loading.
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: placeholderGlyph)
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .clipShape(artworkShape)
    }

    /// A circle for artists, the way every music app draws a person.
    ///
    /// `AnyShape` rather than a branch around two `clipShape` calls: branching
    /// gives SwiftUI two different views to reconcile, so a tile changing kind
    /// under reuse would rebuild rather than redraw. It arrived in iOS 16, one
    /// under the floor.
    ///
    /// The square bounding box is the same either way, so a grid of circles and
    /// squares still lines up.
    private var artworkShape: AnyShape {
        item.id.kind == .artist
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The kind, and — for anything you can open — a caret saying so.
    ///
    /// Trailing on this line rather than beside the title, which is where a
    /// chevron sat once before and had to go: next to the play triangle it was
    /// two rightward wedges at caption size and read as the same mark. Down here
    /// it is pinned to the opposite edge from any glyph, on the line that names
    /// the kind, where it reads as "and this takes you there" instead.
    private var subtitleRow: some View {
        HStack(spacing: 4) {
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: glyph)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.headline)
                // Two lines whether or not the title needs them. Without it a
                // one-line title makes a shorter tile than a two-line one and
                // every grid row sits on a ragged baseline — invisible while
                // tiles were bare, obvious the moment containers grew a card.
                .lineLimit(2, reservesSpace: true)
            Spacer(minLength: 0)
        }
    }

    /// The kind's own mark, on its own silhouette.
    ///
    /// This was a chevron for containers and a play triangle for songs, which
    /// is two rightward wedges at caption size — no distinction at all once
    /// they are 8 points tall and next to each other in a grid.
    ///
    /// Splitting it by kind rather than by action also buys back something the
    /// single chevron lost: an artist and an album are both "opens", so a shared
    /// glyph left them telling apart only by their titles. The card behind the
    /// tile still carries the action; the glyph carries the kind. Two facts, two
    /// channels.
    private var glyph: String {
        switch item.id.kind {
        case .song: "play.fill"
        case .album: "square.stack.fill"
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        }
    }

    private var placeholderGlyph: String {
        switch item.id.kind {
        case .artist: "music.mic"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        // Not `play.fill` here: a play triangle filling the space where artwork
        // should be reads as a button, and this is the one tile you cannot tap
        // to hear anything yet.
        case .song: "music.note"
        }
    }

    /// Always present, so every tile is the same height.
    ///
    /// An artist's `subtitle` is `nil` by design — it would only repeat the
    /// title — which left artist tiles one line shorter than their neighbours
    /// and the grid ragged the moment search started returning them.
    private var subtitle: String {
        item.subtitle ?? item.id.kind.rawValue.capitalized
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.id.kind.rawValue]
        if let subtitle = item.subtitle { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }
}
