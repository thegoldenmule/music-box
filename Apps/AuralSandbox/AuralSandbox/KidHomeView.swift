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
    /// One shelf per grown-up: what each suggested, then their allow list where
    /// the level shows one. See ``Session/grownUpShelves()``.
    @State private var grownUpShelves: [GrownUpShelf] = []
    /// The kid's own favorites, which is what that word describes now.
    @State private var libraryItems: [CatalogItem] = []
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
    /// Starts *true*, because this screen always loads when it appears and the
    /// load is not instant.
    ///
    /// Starting false meant the first frame had no items and nothing in flight,
    /// which is the state that draws "Pick something to listen to" — so a kid
    /// with a full home screen saw it flash the empty screen, then the loader,
    /// then their shelves. The reload is kicked off from `.task`, one frame
    /// later; this is what covers that frame.
    @State private var isLoading = true
    @State private var trouble: String?
    /// Bumped to ask the shelves to go back to the top.
    ///
    /// A counter and not a flag, because two presses of the home button are two
    /// requests and a `Bool` that is already `true` is not a second one. The
    /// scroll view is inside a `ScrollViewReader` and its proxy exists only in
    /// that closure, so this is how a press out in the bottom bar reaches it.
    @State private var scrollHomeToTop = 0
    @State private var showingAdmin = false
    /// How tall the two bottom bars are, measured rather than guessed.
    ///
    /// Guessing is not available: the row is 52 points plus padding, the
    /// now-playing bar is there or not, it grows a line when it has something to
    /// say, and every one of those is a different number. Measuring is also what
    /// keeps this honest when the bars change — nothing here has to be updated
    /// when one of them grows a control.
    ///
    /// It exists because of ``KidHomeView/bottomBars``: the inset that draws
    /// them reserves nothing inside the stack, so every screen in it — the root
    /// included — is handed the height and reserves it itself. See
    /// ``View/reservingBottomBars(_:)``.
    @State private var barHeight: CGFloat = 0
    /// The path lives in a ``KidRouter`` rather than in a plain `@State` for two
    /// reasons. ``NowPlayingView`` covers this stack rather than living in it,
    /// and therefore sits outside it, so it needs a way to push onto it. And
    /// the router's setter is where a repeat push is collapsed — see ``KidRouter/collapsed(_:)``, which
    /// is why the same album cannot end up on the stack twice.
    ///
    /// It is an array of ``KidRoute`` and not a `NavigationPath`. The stack
    /// pushes two unrelated things — a container the kid browsed into and a
    /// screen that is not browsing — and a path holding one concrete type
    /// refuses the other at runtime, which compiles and simply does not work.
    /// One enum carries both *and* stays readable, which a `NavigationPath` is
    /// not: it can be counted and popped, never inspected, so a stack built on
    /// one cannot be asked what is already open.
    @State private var router = KidRouter()
    #if os(iOS)
    /// How far up the full-screen player is. Held here rather than in
    /// ``NowPlayingBar`` because the player is drawn over this whole screen and
    /// the bar is one row inside it — the drag starts in the row and finishes
    /// over the top of everything. See ``PlayerExpansion``.
    @State private var expansion = PlayerExpansion()
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init(session: Session) {
        self.session = session
        _player = State(initialValue: KidPlayerModel(session: session))
    }

    private var canSearch: Bool { session.kid.effectiveMode != .allowOnly }

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
    ///
    /// A suggested playlist contributes nothing: it is a tile that opens, and
    /// the screen behind it queues its own songs.
    private var shown: [CatalogItem] {
        visible
            ?? (recents + libraryItems
                + grownUpShelves.flatMap(\.tiles).compactMap(\.playableItem))
    }

    /// What the results grid is showing, once the filter has had its say.
    private var visible: [CatalogItem]? {
        guard case .results(let results) = search else { return nil }
        return results.items(of: filter.kind)
    }

    var body: some View {
        NavigationStack(path: $router.path) {
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
            // The root reserves the room itself, exactly as a pushed screen
            // does. See ``View/reservingBottomBars(_:)`` — the short version is
            // that the inset out beyond the stack draws the bars and insets
            // nothing inside it, root included.
            .reservingBottomBars(barHeight)
            // **No title.** The kid's own name was the one thing on this screen
            // written for somebody who can read, and a large title is a band of
            // it that scrolls away and comes back — which is also what made the
            // home button land short: `scrollTo` puts the anchor below the title
            // area, so "the top" was the top of a screen with a name on it
            // rather than the top of the shelves.
            //
            // The bar itself stays, because the lock still lives on it.
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // Every push in the app lands here — from search, from a shelf, from
            // a playlist, from an artist's page — because they all sit inside
            // this stack. One destination rather than two, because the path is
            // one array of ``KidRoute`` rather than a type-erased
            // `NavigationPath`; that is what lets ``KidRouter`` see what is
            // already open and refuse to open it twice.
            .navigationDestination(for: KidRoute.self) { route in
                Group {
                    switch route {
                    case .container(let container):
                        browse(container)
                    case .home(let destination):
                        screen(for: destination)
                    }
                }
                // The same reservation the root makes, for the same reason.
                .reservingBottomBars(barHeight)
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
        }
        // **Both bars, one inset, under the whole stack rather than inside it.**
        //
        // Out here because a `searchable` belongs to the navigation container it
        // is applied to and draws on that container's *root*, so the field
        // vanished the moment a kid opened an album — and eight screens deep is
        // exactly where both of these controls are wanted. Nothing here moves
        // when a screen is pushed, because pushing does not touch it.
        //
        // *One* inset and not two, which is the part that has to stay that way:
        // an inset inside the stack and another outside it do not know about
        // each other, and the two bars were drawn over the top of one another.
        // Stacked in a single `VStack` they cannot be — the layout does the
        // arranging, rather than two independent claims on the same edge
        // happening to agree.
        //
        // This is also the only place ``NowPlayingBar`` is drawn now. It used to
        // be a `safeAreaInset` repeated on all eight kid screens, and every one
        // of those repeats was a chance for exactly this bug.
        //
        // **This draws the bars and reserves no room for them.** Applied out
        // here it insets nothing inside the stack — see
        // ``View/reservingBottomBars(_:)``, which is where the room comes from
        // and which the root and every pushed screen both call. Adding the
        // reservation here as well is the doubling to watch for, not the fix.
        .safeAreaInset(edge: .bottom) { bottomBars }
        // The full-screen player, over the stack rather than modally in front of
        // it — the one thing a modal cannot be is half open, and this one is
        // dragged. It covers the bar and the toolbar because it is applied out
        // here, to everything — and now the search bar too, which is the one
        // screen in the app that should not have one.
        #if os(iOS)
        .overlay { ExpandedPlayer(session: session, player: player, expansion: expansion) }
        .environment(expansion)
        #endif
        // Reaches every screen in the stack, and — the point of putting it here
        // — every sheet and cover they present, and the player over the top of
        // them.
        .environment(router)
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
        .task {
            // The trail before the shelf that draws from it: `homeItems()` reads
            // it synchronously, so a reload that ran first would resolve an
            // empty list and the home screen would be blank until something
            // else happened.
            await session.loadRecentTrail()
            reload()
            // The queue came back with the player itself, so the bar is already
            // drawn by the time this runs. This is the second half: what a
            // parent denied while the app was closed comes off it. Nothing plays
            // in between — a restored queue is stopped until the kid presses
            // play, and pressing play asks the engine again anyway.
            await player.revalidate()
        }
        .onChange(of: term) { _, new in
            if new.isEmpty {
                searchTask?.cancel()
                searchTask = nil
                filter = .artists
                withAnimation(.easeInOut(duration: 0.2)) { search = .home }
            }
        }
        // The shelf follows the trail directly now, rather than watching the
        // player and hoping a write had landed. That guess was the bug: the
        // track changed microseconds after the play row was handed to a
        // detached task, so the reload it triggered usually read the store
        // before the row committed. `recentTrail` changes only once the write
        // has actually returned.
        .onChange(of: session.recentTrail) { _, _ in
            if isHome { reloadRecents() }
        }
        // A heart filled or emptied anywhere in the app — a search result, an
        // album, the now-playing screen, a tile on this very screen — changes
        // what belongs on the Library shelf. `refreshLibrary()` already keeps
        // the heart itself and the playlist shelf in step; this is the shelf of
        // resolved items beside them, which nothing was updating.
        .onChange(of: session.favoriteIDs) { _, _ in
            if isHome { reloadLibraryShelf() }
        }
        // Coming back to the root of the stack, after however deep the kid went.
        //
        // The two hooks above are each about one shelf reacting to one thing.
        // This is the backstop for everything else that can have happened while
        // the home screen was covered — a parent editing the allow list from the
        // admin, a playlist deleted, a favorite removed from the library
        // browser — none of which the shelves would otherwise hear about until
        // the app was backgrounded and brought forward again.
        //
        // Without the skeleton: there is already a home screen underneath, and
        // replacing it with placeholders on the way back from an album is a
        // worse answer than a shelf that updates a moment late.
        .onChange(of: router.path.isEmpty) { _, isRoot in
            if isRoot, isHome { Task { await loadShelves() } }
        }
        // A kid switch in the admin changes whose sandbox this is, and what is
        // playing belongs to the child who is no longer using the app. The
        // player stops and picks up the other kid's queue instead.
        .onChange(of: session.kid.id) { _, _ in
            Task {
                await player.switchedKid()
                await player.revalidate()
            }
        }
        // A parent who clears the logs must not find the bar still holding what
        // their child was listening to. The stored queue is already gone; this
        // is the copy on screen.
        .onChange(of: session.historyCleared) { _, _ in
            Task { await player.stop() }
        }
        // A parent's edit reaches the song already playing, not only the one
        // queued behind it. Everything that judges was re-indexed the moment
        // `rebuildEngines()` ran; this is the audio.
        .onChange(of: session.policyGeneration) { _, _ in
            Task { await player.revalidatePlaying() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Otherwise a kid who plays one song and puts the phone down never
            // produces a play event at all — and the queue would come back
            // pointing at the top of a track they were halfway through.
            if phase != .active {
                player.flush()
            } else if isHome {
                reload()
            }

            // `AdminGate.close()`'s own doc says it is "called on background,
            // and on leaving the admin". The second half was true and the first
            // was not, so an admin session left open survived backgrounding and
            // came back open — on the shared iPad, in a child's hands, with the
            // idle timeout the only thing between them and the allow list.
            //
            // **`.background` and not `phase != .active`.** `.inactive` is the
            // app switcher, a system alert, Notification Centre pulled halfway
            // down — a parent glancing at something mid-edit, not a parent
            // leaving. Closing on that would throw away the session they are
            // still in. The flush above is the opposite case and correctly
            // takes both: writing the play event early costs nothing if they
            // come straight back.
            if phase == .background {
                session.closeAdmin()
                showingAdmin = false
            }
        }
    }

    /// The two bars at the bottom of the kid's app, and the one measurement
    /// every screen behind them depends on.
    ///
    /// The height goes out through ``barHeight``, taken from a
    /// `GeometryReader` in the background so that measuring costs the bars no
    /// height of their own and cannot feed a size back into the thing being
    /// sized. Through a preference rather than written from inside the reader's
    /// body — that is a mutation during layout, which SwiftUI is entitled to
    /// complain about or to loop on. The same shape as ``WidthKey`` on the album
    /// screen, for the same reason.
    private var bottomBars: some View {
        VStack(spacing: 0) {
            // What is playing sits above what to do next.
            NowPlayingBar(session: session, player: player)
            KidSearchBar(canSearch: canSearch, term: $term, onSubmit: runSearch, onHome: goHome)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: BarHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
    }

    // MARK: - Destinations

    /// An album and an artist each get a screen shaped like what they are; a
    /// playlist is a grid of pictures, which is what browsing was before either
    /// of them existed.
    @ViewBuilder
    private func browse(_ container: CatalogItem) -> some View {
        Group {
            switch container.id.kind {
            case .album:
                AlbumView(session: session, player: player, album: container)
            case .artist:
                ArtistView(session: session, player: player, artist: container)
            default:
                BrowseView(session: session, player: player, container: container)
            }
        }
        // The one place a container open is recorded, for the same reason this is
        // the one place a container is opened. It catches a tile from a shelf, a
        // search result, an artist's album, and the cover on the now-playing
        // screen — which reaches the path through ``KidRouter`` and would need
        // its own hook otherwise.
        //
        // Here rather than inside the destination's own `load()`, because a kid
        // reached this screen whether or not the track list came back, and
        // because "Try again" re-runs `load()` and is not a second arrival. A
        // `.task` that fires twice is harmless: the walk collapses a repeat and
        // the projector coalesces the row.
        .task { await session.noteVisit(container, manner: .opened) }
    }

    /// The screens that are not browsing.
    @ViewBuilder
    private func screen(for route: HomeRoute) -> some View {
        switch route {
        case .history:
            HistoryView(session: session, player: player)
        case .library:
            LibraryView(session: session, player: player)
        case .libraryArtist(let id):
            LibraryArtistView(session: session, player: player, artist: id)
        case .libraryAlbum(let id):
            LibraryAlbumView(session: session, player: player, album: id)
        case .playlist(let handle):
            PlaylistView(session: session, player: player, handle: handle)
        case .suggestions(let grownUp):
            SuggestionsView(session: session, player: player, grownUp: grownUp)
        case .suggestedPlaylist(let local):
            SuggestedPlaylistView(session: session, player: player, local: local)
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
                SongList(session: session, items: items, origin: .search(term: term)) { item in
                    Task { await playSong(item) }
                }
            } else {
                TileGrid(session: session, items: items, origin: .search(term: term)) { item in
                    Task { await playSong(item) }
                }
            }
        }
    }

    /// Everything the home button undoes.
    ///
    /// **Both ways of leaving home, because either one alone leaves the kid
    /// somewhere that is not home.** The stack is one of them; a set of search
    /// results standing where the shelves go is the other, and popping an album
    /// that was opened from results lands back on the results.
    private func goHome() {
        router.path.removeAll()
        searchTask?.cancel()
        searchTask = nil
        // What empties the field itself, and done here rather than left to the
        // `onChange` below because that fires only when the term was not already
        // empty — which is the case where a kid cleared the box by hand and is
        // still looking at the results it fetched.
        term = ""
        filter = .artists
        withAnimation(.easeInOut(duration: 0.2)) { search = .home }

        // Unconditionally, which covers the case the button is otherwise silent
        // for: already home, already at the root, nothing to clear, and a kid
        // who has scrolled to the bottom of their shelves and pressed the one
        // control that is meant to take them back to the start. It costs
        // nothing anywhere else — a home screen arriving from search or from a
        // pop is drawn at the top regardless.
        scrollHomeToTop += 1
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
        if isLoading && isHomeEmpty {
            HomeSkeleton()
        } else if isHomeEmpty {
            ContentUnavailableView {
                Label(
                    session.kid.effectiveMode == .allowOnly
                        ? "Nothing here yet"
                        : "Pick something to listen to",
                    systemImage: "music.note.list"
                )
            }
        } else {
            ScrollViewReader { proxy in
                shelves
                    .onChange(of: scrollHomeToTop) { _, _ in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(Self.homeTop, anchor: .top)
                        }
                    }
            }
        }
    }

    /// The shelves themselves, lifted out of ``home`` only so the
    /// `ScrollViewReader` around them has one thing to wrap.
    private var shelves: some View {
        ScrollView {
            // Nothing to look at — somewhere to scroll to. A zero-height anchor
            // rather than the stack's own id, because "the top of the shelves"
            // is a fixed point and the stack is a thing whose height changes
            // every time a shelf loads.
            //
            // **Outside the spaced stack, not the first thing in it.** A child
            // of a `VStack(spacing: 24)` is worth 24 points of gap even when it
            // is worth no height, so as the first row it pushed every shelf down
            // by a shelf-gap of nothing.
            VStack(spacing: 0) {
                Color.clear.frame(height: 0).id(Self.homeTop)

                content
            }
            // Barely anything at the top: the toolbar is already a band of empty
            // above this, and a second one under it is the whole complaint.
            .padding(.top, 4)
            .padding(.bottom)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !recents.isEmpty {
                Section {
                    TileShelf(session: session, items: recents, origin: .home) { item in
                        Task { await playSong(item) }
                    }
                } header: {
                    ShelfHeader(title: "Recent", route: .history)
                }
            }

            // "Library" means the kid's own favorites. It used to
            // label the list a parent built, which was the app telling a
            // kid that someone else's choices were their own.
            if !libraryItems.isEmpty {
                Section {
                    TileShelf(session: session, items: libraryItems, origin: .home) { item in
                        Task { await playSong(item) }
                    }
                } header: {
                    ShelfHeader(title: "Library", route: .library)
                }
            }

            if !session.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Playlists").font(.title2.bold()).padding(.horizontal)
                    PlaylistShelf(playlists: session.playlists)
                }
            }

            // One shelf per grown-up, named. Within each: what they suggested,
            // then what they allowed and have not suggested — one heading over
            // both, because the kid's question is *what did they pick for me*
            // and two headings answering it differently is the app showing its
            // own bookkeeping. Split across adults because two parents curate
            // separately, and a merged shelf would credit all of it to whoever
            // the app named first. A shelf rather than the wrapping grid this
            // used to be: the allow list was bounded by what a parent would type
            // into a list editor, and suggestions are not.
            ForEach(grownUpShelves) { shelf in
                Section {
                    SuggestedShelf(
                        session: session,
                        tiles: shelf.tiles,
                        onPlay: { item in Task { await playSong(item, origin: .suggestion) } },
                        onDismiss: dismiss
                    )
                } header: {
                    ShelfHeader(title: shelf.title, route: .suggestions(shelf.id))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The top of the shelves, as something `scrollTo` can be handed.
    private static let homeTop = "home-top"

    private var isHomeEmpty: Bool {
        recents.isEmpty && libraryItems.isEmpty && grownUpShelves.isEmpty
            && session.playlists.isEmpty
    }

    // MARK: - Loading

    /// Re-resolves the Recent shelf and nothing else.
    ///
    /// Cheap where the whole reload is not: the kid just tapped one of these, so
    /// `CachingCatalogSource` usually has every item warm and this costs no
    /// request at all. Separated because it now runs on every arrival rather
    /// than on the handful of moments the full reload was written for.
    private func reloadRecents() {
        Task {
            guard let items = try? await session.homeItems() else { return }
            recents = items
        }
    }

    /// Re-resolves the Library shelf and nothing else.
    ///
    /// The counterpart to ``reloadRecents()``, and it exists for the same reason
    /// that one does: `favoriteIDs` is what the heart draws from and it updates
    /// on every write, but the *shelf* is a resolved list of items that only the
    /// full reload ever built. So a kid could fill a heart, watch it fill, and
    /// find the shelf below it unchanged — the tap plainly having worked and
    /// plainly having done nothing.
    ///
    /// Cheap for the same reason too: the kid just had this item on screen, so
    /// the item cache is warm and this usually costs no request at all.
    private func reloadLibraryShelf() {
        Task {
            guard let items = try? await session.favoriteItems() else { return }
            libraryItems = items
        }
    }

    /// The three shelves, together.
    ///
    /// Separated from ``reload()`` so that a refresh can happen without the
    /// skeleton: `isLoading` swaps the whole screen for placeholder tiles, which
    /// is right on a cold launch with nothing to show and wrong every other
    /// time. A kid coming back from an album would watch their home screen
    /// dissolve into grey boxes and reassemble.
    private func loadShelves() async {
        // The heart and the playlist shelf read from rows already in memory, so
        // this costs nothing and has to happen before the shelves draw.
        await session.refreshLibrary()
        do {
            // Started together, not one after another. Each of these is a round
            // trip to Apple Music — the item cache is rebuilt empty with the
            // process, so a cold launch resolves every recent and every favorite
            // over the network — and awaiting them in turn made the wait their
            // sum when it only ever needed to be their maximum. Nothing here
            // depends on anything else here.
            async let recentItems = session.homeItems()
            async let favorites = session.favoriteItems()
            async let grownUp = session.grownUpShelves()
            (recents, libraryItems, grownUpShelves) = try await (recentItems, favorites, grownUp)
        } catch {
            trouble = Session.kidMessage(for: error)
        }
    }

    /// The kid passed on a suggestion.
    ///
    /// The tile goes and so does the reach it granted, which is why this
    /// re-reads the shelf rather than filtering the one tile out of the array
    /// in hand: a suggested album's allow reached its tracks, and anything else
    /// on the shelf that was only standing because of it has to go too.
    private func dismiss(_ row: SuggestionRow) {
        if let failure = session.dismissSuggestion(row) {
            trouble = failure
            return
        }
        Task { await loadShelves() }
    }

    private func reload() {
        Task {
            isLoading = true
            defer { isLoading = false }
            await loadShelves()
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

        // Results are drawn at the root of the stack, and the field that asked
        // for them is now reachable from anywhere in it — so a search run from
        // three screens deep would land behind three screens. Popping is what
        // makes searching from an album page mean anything.
        router.path.removeAll()

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
                trouble = Session.kidMessage(for: error)
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
    /// - Parameter origin: overrides the shelf-or-search default, for a shelf
    ///   that is neither. The grown-up shelf passes `.suggestion` so the report
    ///   can answer whether the kid played what the parent picked — folded into
    ///   `.home` that question has no answer, and it is not one old rows can be
    ///   taught later.
    private func playSong(_ item: CatalogItem, origin: PlaybackOrigin? = nil) async {
        let origin = origin ?? (isHome ? .home : .search(term: term))
        await player.play(item, from: shown.filter { $0.id.kind == .song }, origin: origin)
    }
}

extension View {
    /// Reserves the room the two bottom bars occupy.
    ///
    /// **The bars are drawn once, out beyond the stack; the room for them is
    /// reserved by every screen, and there are no exceptions.** A
    /// `safeAreaInset` applied to a `NavigationStack` draws its content and
    /// insets *nothing inside the stack* — not the pushed screens, and **not the
    /// root either**. So each screen adds a clear spacer of the measured height.
    ///
    /// That the root is included is the part worth writing down, because getting
    /// it wrong is what kept this bug alive. The first pass at it fixed the
    /// pushed screens and left a comment saying the inset "insets the stack's
    /// root and does not reach anything pushed onto it" — half right, and the
    /// wrong half was the half that told every later reader the home screen was
    /// already handled. It was not: home had a shelf under the search bar the
    /// whole time, and the only reason it took this long to be unmissable is
    /// that the shelf which ended up last used to be there only at level 1.
    /// A comment asserting something untested is worse than no comment, because
    /// it stops the next person looking.
    ///
    /// A clear spacer rather than a second copy of the bars: the height is the
    /// only part of them a screen needs, and drawing them twice is exactly the
    /// doubling that moved them out of the stack to begin with. A
    /// `safeAreaInset` rather than padding or `contentMargins`, so that a scroll
    /// view insets its content by it *and* a screen that does not scroll — a
    /// "Nothing to play here", a spinner — centres itself in what is left rather
    /// than behind the bar.
    ///
    /// The window's own bottom inset is already in every screen's safe area,
    /// which is why this adds the bars' height alone.
    ///
    /// If a new kid-facing screen is ever hosted somewhere other than
    /// ``KidHomeView``'s stack, it needs this too. Inside that stack it is
    /// inherited: the root has it, and every pushed screen gets it from the one
    /// `navigationDestination`.
    func reservingBottomBars(_ height: CGFloat) -> some View {
        safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: height)
        }
    }
}

/// The measured height of the two bottom bars, passed up from where they are
/// drawn to the screens that have to leave room for them.
///
/// `max` rather than last-writer-wins: there is one bar stack and so one value,
/// and taking the larger of any two is the reading that cannot end up reserving
/// less room than something on screen occupies.
struct BarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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

/// Where the home screen can go. A `CatalogItem` push is browsing; these are not.
enum HomeRoute: Hashable {
    case history
    /// Everything the kid has kept, by kind, with a filter over each.
    case library

    /// One artist's albums **as they exist in the library**.
    ///
    /// Not `.container(artist)`, and the difference is the whole feature: that
    /// route opens the artist's catalog page and everything they ever released.
    /// This one is closed over what the kid has kept, which is what makes the
    /// browser a library browser rather than a second way into the catalog.
    case libraryArtist(CatalogID)

    /// One album's songs, again only the ones in the library.
    case libraryAlbum(CatalogID)

    case playlist(PlaylistHandle)

    /// The whole of one grown-up's shelf, behind its chevron.
    ///
    /// Carries a ``GrownUpShelf/id`` — an attribution, or the sentinel for the
    /// shelf nobody is named on. A route rather than a filter applied by the
    /// screen, because the home screen is where the shelves are already split and
    /// the chevron has to open the one it sits under.
    case suggestions(String)

    /// One suggested playlist that only exists here, by its local identifier.
    ///
    /// Not `.playlist(_:)`, which takes a ``PlaylistHandle`` and means one the
    /// kid owns — a different table, a different screen, and a different set of
    /// things the kid may do to it.
    case suggestedPlaylist(UUID)
}

/// A shelf's title, and the way into the whole of it.
///
/// The caret is the affordance; the title is the target. A shelf shows what fits
/// on one line, and the screen behind it shows the rest — which is what makes it
/// safe for a shelf to be short.
struct ShelfHeader: View {
    let title: String
    let route: HomeRoute

    var body: some View {
        NavigationLink(value: KidRoute.home(route)) {
            HStack {
                Text(title).font(.title2.bold())
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }
}

/// Playlists, sideways, the way Recent is.
///
/// A card rather than a tile: a playlist has no artwork of its own, and
/// borrowing the first song's would be compositing a name onto Apple's pixels.
struct PlaylistShelf: View {
    let playlists: [PlaylistRow]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(playlists) { playlist in
                    NavigationLink(value: KidRoute.home(.playlist(playlist.handle))) {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

struct PlaylistCard: View {
    let playlist: PlaylistRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 150, height: 150)

            Text(playlist.name)
                .font(.headline)
                .lineLimit(2, reservesSpace: true)
            Text(playlist.entries.count == 1 ? "1 song" : "\(playlist.entries.count) songs")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(width: 150)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens"))
    }
}

/// What the home screen looks like while its shelves are still resolving.
///
/// Placeholder tiles rather than a spinner, because of how long this is on
/// screen: every shelf here is fetched from Apple Music on a cold launch — the
/// item cache is rebuilt empty with the process — so this is up for as long as
/// those round trips take. A small spinner alone in the middle of a phone reads
/// as a blank screen for that whole time. Shapes where the tiles are about to
/// be read as something arriving, and they arrive in the same places.
///
/// Deliberately not `.redacted(reason: .placeholder)` over real tiles: there
/// are no real tiles yet, and inventing ``CatalogItem`` values to redact would
/// put fabricated catalog data on a kid's screen to hide it again.
///
/// Two shelves and four tiles because that is roughly a phone's worth, not
/// because it predicts what lands — the count is scenery, and a shelf that
/// turns out to be empty simply is not drawn a moment later.
struct HomeSkeleton: View {
    /// Matches ``TileShelf``, so nothing jumps sideways on the swap — including
    /// the scaling, or the placeholders would be one width and the tiles that
    /// replace them another.
    @ScaledMetric(relativeTo: .headline) private var tileWidth: CGFloat = 150

    /// The pulse. Without it a grey screen reads as broken rather than busy;
    /// slow enough to be calm, since a kid is looking at it.
    @State private var dimmed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                shelf
                shelf
            }
            .padding(.vertical)
        }
        .opacity(dimmed ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
        .onAppear { dimmed = true }
        // Nothing here is real, so nothing here is tappable, and VoiceOver is
        // told what it is once rather than reading out eight empty shapes.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            block(width: 120, height: 26, radius: 6)
                .padding(.horizontal)
            HStack(alignment: .top, spacing: 16) {
                ForEach(0..<4, id: \.self) { _ in tile }
            }
            .padding(.horizontal)
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
            block(width: nil, height: 15, radius: 4)
            block(width: 80, height: 13, radius: 4)
        }
        .padding(Tile.padding)
        .frame(width: min(tileWidth, TileShelf.maxTileWidth))
    }

    private func block(width: CGFloat?, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(.quaternary)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A shelf of tiles, sideways.
///
/// One row, scrolled horizontally, so it never pushes the rest of the home
/// screen off the bottom no matter how much a kid listens to or keeps. Recents
/// and favorites are both this: neither has a bound, and both have a screen
/// behind them holding the whole of it.
struct TileShelf: View {
    @Bindable var session: Session
    let items: [CatalogItem]
    let origin: PlaybackOrigin
    let onPlay: (CatalogItem) -> Void

    /// A grid column has a width and hands it to the tile. An `HStack` does
    /// not: the tile sizes to its content, so a long song title stretches the
    /// tile instead of wrapping inside it, and one tile fills the screen.
    ///
    /// **Scaled, because the words inside it scale.** At a fixed 150 the title
    /// truncated to "Tig r…" long before the type stopped growing, which on the
    /// one shelf a pre-literate child navigates by sight is the wrong thing to
    /// give up. ``HomeSkeleton`` scales the same way so nothing jumps sideways
    /// on the swap.
    @ScaledMetric(relativeTo: .headline) private var tileWidth: CGFloat = 150

    /// Past this the tile is wider than the phone it is on and one tile fills
    /// the screen. A judgement, not a measurement — worth a look on a device at
    /// the largest sizes.
    ///
    /// Not private, because ``HomeSkeleton`` has to clamp at the same number or
    /// the placeholders are one width and the tiles that replace them another.
    static let maxTileWidth: CGFloat = 280

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    TileCell(session: session, item: item, origin: origin, onPlay: onPlay)
                        .frame(width: min(tileWidth, Self.maxTileWidth))
                }
            }
            .padding(.horizontal)
        }
        // **No height here, and that is the fix rather than an omission.**
        //
        // This used to be `.frame(height: tileWidth + 84)`, where 84 was a
        // hand-computed allowance for two lines of title and one of subtitle.
        // It was redundant — `titleRow` already reserves both lines with
        // `lineLimit(2, reservesSpace:)` and `subtitleRow` carries a `minHeight`,
        // so every tile is the same height by construction — and it was actively
        // harmful, because the artwork is `aspectRatio(1, contentMode: .fit)` and
        // therefore the one flexible thing in the stack. Constrain the height and
        // growing text does not overflow the tile: it *evicts the picture*. At
        // the largest accessibility sizes the covers shrank to roughly a quarter
        // size, so the setting that exists for people who cannot read small text
        // was where this app took the pictures away and kept the words.
        //
        // Unconstrained, the stack sizes to artwork plus text and the artwork is
        // never squeezed. Found by running the app at
        // `accessibility-extra-extra-extra-large`; see `STYLE.md` §3.4.
    }
}

/// A wrapping grid that does not scroll — for use inside a page that already
/// does. Nesting two scroll views breaks the outer one's gestures.
struct TileWrap: View {
    @Bindable var session: Session
    let items: [CatalogItem]
    let origin: PlaybackOrigin
    let onPlay: (CatalogItem) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
            ForEach(items, id: \.id) { item in
                TileCell(session: session, item: item, origin: origin, onPlay: onPlay)
            }
        }
        .padding(.horizontal)
    }
}

/// Big, square, tappable. Sized for a finger that is not very accurate yet.
struct TileGrid: View {
    @Bindable var session: Session
    let items: [CatalogItem]
    let origin: PlaybackOrigin
    let onPlay: (CatalogItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    TileCell(session: session, item: item, origin: origin, onPlay: onPlay)
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
    @Bindable var session: Session
    let items: [CatalogItem]
    let origin: PlaybackOrigin
    let onPlay: (CatalogItem) -> Void
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ScrollView {
            SongRows(session: session, items: items, origin: origin, onPlay: onPlay)
            footer()
        }
    }
}

/// The rows on their own, for a page that already scrolls.
///
/// Split out of ``SongList`` rather than copied: an artist's page stacks a header
/// and a shelf above its songs, and nesting a second scroll view inside that one
/// breaks the outer one's gestures — the same reason ``TileWrap`` exists beside
/// ``TileGrid``.
struct SongRows: View {
    @Bindable var session: Session
    let items: [CatalogItem]
    let origin: PlaybackOrigin
    let onPlay: (CatalogItem) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            // Indexed, so the separator is decided by position rather than by
            // comparing against the last item's identifier. That comparison drops
            // the rule under any row that happens to share an id with the last
            // one — which is only ever the case when something upstream has
            // leaked a duplicate, but it turns one bug into two and hides the
            // shape of the first.
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    // Inset past the artwork, so the rule reads as a break
                    // between titles rather than a line across the page.
                    Divider().padding(.leading, SongRowMetrics.textInset)
                }
                SongRow(item: item) {
                    onPlay(item)
                } accessory: {
                    HeartButton(session: session, item: item, origin: origin)
                    AddToPlaylistButton(session: session, item: item, origin: origin)
                }
            }
        }
    }
}

extension SongList where Footer == EmptyView {
    init(
        session: Session,
        items: [CatalogItem],
        origin: PlaybackOrigin,
        onPlay: @escaping (CatalogItem) -> Void
    ) {
        self.init(
            session: session,
            items: items,
            origin: origin,
            onPlay: onPlay,
            footer: { EmptyView() }
        )
    }
}

/// A song row's measurements.
///
/// Outside ``SongRow`` because it is generic now, and a static on a generic type
/// cannot be named without supplying the parameter — `SongRow.textInset` stops
/// compiling the moment the row gains an accessory slot.
enum SongRowMetrics {
    static let artworkSize: CGFloat = 56
    static let margin: CGFloat = 16
    static let gap: CGFloat = 12

    /// Where the text starts, which is where a separator should too.
    static var textInset: CGFloat { margin + artworkSize + gap }
}

/// One song: artwork, what it is, and the controls at the end.
///
/// **Three sibling controls, not one with others inside it.** Tapping the title
/// plays, tapping the heart favorites, tapping the menu adds to a playlist — and
/// a button inside another button's label is dead, so the row cannot be one big
/// button with the rest laid on top. The play target is the artwork, the titles
/// and the gap between them and the heart, which is most of the row.
struct SongRow<Accessory: View>: View {
    let item: CatalogItem
    let onPlay: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onPlay) {
                HStack(spacing: SongRowMetrics.gap) {
                    artwork
                    VStack(alignment: .leading, spacing: 2) {
                        // Two lines, not truncated to one. Rows in a list are
                        // allowed to differ in height — the grid's alignment
                        // problem does not exist here — and cutting off the
                        // title of the thing being chosen is the worse trade.
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
                    Spacer(minLength: SongRowMetrics.gap)
                }
                // The whole of it, including the gap the Spacer opens up, not
                // just the parts with something drawn on them.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
            )
            .accessibilityHint(Text("Plays"))

            // The heart at the leading edge of the trailing controls, beside the
            // play button — never on the artwork. Clipping is ours to do;
            // compositing onto Apple's pixels is not. See `Tile.artwork`.
            accessory()

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: HeartButton.size, height: HeartButton.size)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play")
        }
        .padding(.horizontal, SongRowMetrics.margin)
        .padding(.vertical, 10)
    }

    private var artwork: some View {
        ArtworkImage(url: item.artworkURL) { image in
            image.resizable().aspectRatio(1, contentMode: .fit)
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").foregroundStyle(.tertiary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .frame(width: SongRowMetrics.artworkSize, height: SongRowMetrics.artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct Tile: View {
    let item: CatalogItem

    /// Whether to leave a gap on the subtitle line for a heart.
    ///
    /// Space rather than the control itself: the heart has to be a sibling of
    /// whatever makes the tile tappable, not a button inside another button's
    /// label, so ``TileCell`` lays it into this gap from outside. A tile with no
    /// gap and a tile with one are otherwise identical, which is what keeps a
    /// grid of both lined up.
    var hasHeart = false

    /// The tile's own inset. ``TileCell`` matches it when placing the heart.
    static let padding: CGFloat = 8

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
        .padding(Self.padding)
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
        ArtworkImage(url: item.artworkURL) { image in
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
            if hasHeart {
                // The gap the heart is laid into, and the reason this line has a
                // minimum height: the tile must be the same size whether or not
                // one is coming, or a grid of shelves and search results ends up
                // ragged.
                Color.clear
                    .frame(width: HeartButton.size, height: HeartButton.size)
            }
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
        .frame(minHeight: HeartButton.size)
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
