import AdminGate
import CatalogKit
import FamilyStore
import Foundation
import KidLibrary
import SwiftData

/// Everything one run of the app needs, wired together once.
///
/// Holds the family, whichever kid is active, and the admin gate. The kid's
/// screen and the parent's admin both read from here, which is what keeps a
/// policy edit in the admin visible to the player without a reload.
@MainActor
@Observable
final class Session {
    /// What Apple Music will allow, before any of it is worth showing.
    ///
    /// There is deliberately no `failed` case. Not being able to *reach* Apple
    /// is not an answer about the account, and it used to be treated as one:
    /// any error out of the subscription check replaced the whole app with a
    /// message about Apple Music not answering. See ``start()``.
    enum Access {
        case checking
        case needsAuthorization(AuthorizationStatus)
        case cannotPlay(SubscriptionState)
        case ready
    }

    private(set) var access: Access = .checking

    let container: ModelContainer
    let eventLog: EventLog

    /// Reads a kid's whole history, unfiltered.
    ///
    /// A third context: the admin writes policy on `context`, the kid's session
    /// writes events through ``EventLog``, and this only ever reads — reading a
    /// report must never appear in the report. Held for the life of the session
    /// because it is stateless: which kid it is asked about is a parameter and
    /// not a property, so a parent can review one child while another is
    /// mid-song.
    let review: ReviewReader

    /// Writes visits and keeps the Recent shelf in step with them.
    ///
    /// Separate from ``eventLog`` because the contract is the opposite one: that
    /// is fire-and-forget and swallows failures, which is right for a report
    /// line and wrong for a shelf a kid is looking at. See ``RecentsProjector``.
    let recents: RecentsProjector
    let player: MusicKitPlayer
    let passcodes: any PasscodeStore

    /// Every kid in the family, in insertion order.
    private(set) var kids: [Kid] = []

    /// Whose sandbox the player is currently inside.
    ///
    /// Switching this happens only inside the admin — a kid cannot become
    /// another kid, which would be the simplest possible escape.
    private(set) var kid: Kid

    /// The admin gate. A value the app advances, not a timer.
    private(set) var gate = AdminGate()

    /// Rebuilt whenever the active kid's policy changes — the engine indexes
    /// the lists once, so it is per-policy rather than per-search.
    private(set) var catalog: FilteredCatalog

    /// The kid's own favorites and playlists, across every provider holding
    /// them. Rebuilt alongside ``catalog`` and for the same reason.
    private(set) var library: MergedLibrary

    /// What the heart draws from.
    ///
    /// Held here rather than asked for per row: a search page of twenty-four
    /// songs asks this twenty-four times as it scrolls, and it has to be a set
    /// lookup against rows already in memory rather than anything that touches
    /// the store. Refreshed after every write and on every kid switch.
    ///
    /// **Not policy filtered.** It answers "is this favorited", and a blocked
    /// item never reaches a screen that could ask.
    private(set) var favoriteIDs: Set<CatalogID> = []

    /// Every playlist, most recently touched first. Names and counts only —
    /// the songs are resolved by the screen that shows them.
    private(set) var playlists: [PlaylistRow] = []

    /// The Recent shelf, newest first, as the projector last left it.
    ///
    /// **Not policy filtered, and it must never become so.** This is what the
    /// kid *reached*; whether they may still reach it is decided at render time,
    /// every time, because a parent can deny between the arrival and the draw.
    /// See ``homeItems(limit:)``.
    private(set) var recentTrail: [RecentEntry] = []

    /// Whether the Apple Music library on this device is the kid's own, and
    /// whether anyone has been asked.
    ///
    /// A mirror of what the store holds, so the admin's switch and the
    /// onboarding question redraw. ``MergedLibrary`` reads the store directly
    /// and is not looking at this copy — which is what keeps the answer
    /// authoritative in one place rather than two.
    private(set) var deviceLibrary: DeviceLibraryState = .unasked

    /// What each kid was playing when the app last closed.
    ///
    /// Device-local for the reason ``deviceLibraryStore`` is: a queue describes
    /// one device's speaker, and syncing it would have a second device resume
    /// something nobody there pressed play on. Held on the session rather than
    /// inside ``KidPlayerModel`` so a history wipe can reach it — see
    /// ``deleteHistory(for:)``.
    let playQueues: any PlayQueueStore = UserDefaultsPlayQueueStore()

    /// Bumped whenever the active kid's history is cleared.
    ///
    /// A counter rather than a callback into the player, which would be a
    /// reference from the session back up into the view layer it is read by. The
    /// kid's screen watches this and stops the player; the alternative was a
    /// parent wiping the logs and finding the bar still holding the track their
    /// child was on, which is the same loophole ``RecentTrailRecord`` is exempt
    /// from the sweep and not from a wipe to avoid.
    private(set) var historyCleared = 0

    private let family: Family
    private let context: ModelContext
    private let musicAccess = MusicKitAccess()
    private let source: any CatalogSource

    /// Where the shared-device answer is kept. Device-local, never synced.
    private let deviceLibraryStore: any DeviceLibraryStateStore = UserDefaultsDeviceLibraryState()

    init(passcodes: any PasscodeStore = KeychainPasscodeStore()) throws {
        container = try FamilyStore.container()
        context = ModelContext(container)
        eventLog = EventLog(modelContainer: container)
        review = ReviewReader(modelContainer: container)
        recents = RecentsProjector(modelContainer: container)
        player = MusicKitPlayer()
        self.passcodes = passcodes

        let (family, kid) = try Self.load(from: context)
        self.family = family
        self.kid = kid

        let source = CachingCatalogSource(
            wrapping: MusicKitCatalogSource(),
            cache: InMemoryItemCache()
        )
        self.source = source
        catalog = FilteredCatalog(source: source, engine: kid.makeEngine())
        library = MergedLibrary(
            // One provider, and it is always live. The Apple Music provider is
            // the next stage; nothing above this line changes when it arrives.
            providers: [CloudKitLibraryProvider(kid: kid, context: context)],
            catalog: source,
            engine: kid.makeEngine(),
            device: deviceLibraryStore
        )
        kids = family.kids
        deviceLibrary = deviceLibraryStore.state
    }

    /// The family, and one kid to start in.
    ///
    /// Level 2 for a first kid because that is the default the product
    /// recommends, and because level 1 with an empty allow list shows nothing
    /// at all — a correct result that reads as a broken app.
    private static func load(from context: ModelContext) throws -> (Family, Kid) {
        var descriptor = FetchDescriptor<Family>()
        descriptor.fetchLimit = 1

        if let family = try context.fetch(descriptor).first, let kid = family.kids.first {
            return (family, kid)
        }

        let family = Family()
        let kid = Kid(name: "Kid", mode: .denyPlusAuto, unratedBehavior: .block)
        context.insert(family)
        context.insert(kid)
        family.addKid(kid)
        try context.save()
        return (family, kid)
    }

    // MARK: - The admin gate

    var isPasscodeSet: Bool { passcodes.isConfigured }

    var isAdminOpen: Bool { gate.isOpen(at: .now) }

    /// Seconds the parent must wait before another attempt, or `nil` if none.
    var retryDelay: TimeInterval? { gate.retryDelay(at: .now) }

    /// Sets the first passcode. Only legal while none is set — otherwise this
    /// would be the reset path that a gate must not have.
    func setPasscode(_ passcode: String) -> String? {
        guard !isPasscodeSet else { return "A passcode is already set." }
        do {
            try passcodes.save(PasscodeRecord.make(passcode))
            gate.succeeded(at: .now)
            return nil
        } catch {
            return "Couldn't save the passcode: \(error)"
        }
    }

    /// Tries a passcode. Returns nil on success, a message otherwise.
    func unlockAdmin(with passcode: String) -> String? {
        guard gate.isAcceptingAttempts(at: .now) else {
            return "Too many attempts. Try again in \(Int(retryDelay ?? 0))s."
        }
        guard let record = try? passcodes.record(), record.matches(passcode) else {
            let delay = gate.failed(at: .now)
            // No hint about length, no note of how close it was.
            return delay.map { "Wrong passcode. Try again in \(Int($0))s." }
                ?? "Wrong passcode."
        }
        gate.succeeded(at: .now)
        return nil
    }

    func touchAdmin() { gate.touch(at: .now) }

    func closeAdmin() { gate.close() }

    // MARK: - Kids

    /// Moves the app into another kid's sandbox.
    ///
    /// The play in progress is written **before** the switch, because
    /// ``logCurrentPlay()`` files it under whoever ``kid`` is at the time. Doing
    /// it afterwards would put one child's listening in another child's report,
    /// which is the one thing a report cannot be allowed to do. The player is
    /// stopped by the kid's screen watching ``kid`` change — see
    /// ``KidPlayerModel/switchedKid()``.
    func switchTo(_ kid: Kid) {
        flushCurrentPlay()
        self.kid = kid
        recentTrail = []
        rebuildCatalog()
        Task { await loadRecentTrail() }
    }

    /// Reads the shelf back from the projector.
    ///
    /// On launch and on a kid switch — the only two moments it is not already in
    /// hand, because every visit returns the trail it produced.
    func loadRecentTrail() async {
        let kidID = kid.id
        guard let trail = try? await recents.trail(for: kidID), kidID == kid.id else { return }
        recentTrail = trail
    }

    @discardableResult
    func addKid(named name: String) -> String? {
        let kid = Kid(name: name, mode: .denyPlusAuto, unratedBehavior: .block)
        context.insert(kid)
        family.addKid(kid)
        let failure = saveLists()
        kids = family.kids
        return failure
    }

    func rename(_ kid: Kid, to name: String) -> String? {
        kid.rename(to: name)
        return saveLists()
    }

    /// Deleting a kid takes their lists and their history with them — the
    /// cascade is in the schema. Refuses to remove the last one, because an
    /// app with no kid has nowhere to go.
    func delete(_ kid: Kid) -> String? {
        guard family.kids.count > 1 else { return "A family needs at least one kid." }
        let wasActive = kid.id == self.kid.id
        // The cascade is in the schema and reaches nothing outside the store, so
        // the device-local queue has to be named. A kid removed and re-added
        // would otherwise come back holding the first one's last album.
        playQueues.clear(for: kid.id)
        family.removeKid(kid)
        context.delete(kid)
        let failure = saveLists()
        kids = family.kids
        if wasActive, let first = family.kids.first {
            switchTo(first)
        }
        return failure
    }

    // MARK: - The parent's review

    /// A library reader for **any** kid, not just the active one.
    ///
    /// Built per call rather than held: the active kid's ``library`` is a
    /// long-lived object the kid's screens draw from, and handing the admin the
    /// same one would tie a parent's reading to whoever is playing.
    func reviewLibrary(for kid: Kid) -> MergedLibrary {
        MergedLibrary(
            providers: [CloudKitLibraryProvider(kid: kid, context: context)],
            catalog: source,
            engine: kid.makeEngine(),
            device: deviceLibraryStore
        )
    }

    /// Names for identifiers a report holds and does not store.
    ///
    /// Block rows keep an artist *identifier* and their own title, so a group of
    /// one artist's tracks would otherwise be labelled with whichever song was
    /// blocked most recently. Best-effort and never awaited before the screen
    /// draws: a name that does not arrive leaves the row reading as what it is.
    func names(for ids: [CatalogID]) async -> [CatalogID: String] {
        guard !ids.isEmpty, let items = try? await source.items(for: ids) else { return [:] }
        return Dictionary(items.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// Approve-from-report, or deny-from-report, on any kid.
    ///
    /// Goes through the same ``addEntry(kind:id:displayName:artworkURL:)`` the
    /// list editor uses — awaited, with its failure surfaced. Nothing about a
    /// report row is a permission on its own; this is a parent tapping.
    ///
    /// Past events are **not** rewritten. A block keeps the reason that produced
    /// it; only the annotation changes on the next read.
    func addEntry(
        for kid: Kid,
        kind: PolicyEntry.Kind,
        id: CatalogID,
        displayName: String
    ) -> String? {
        kid.addEntry(kind: kind, id: id, displayName: displayName)
        do {
            try context.save()
        } catch {
            return error.localizedDescription
        }
        // Only the active kid has live screens to rebuild.
        if kid.id == self.kid.id { rebuildCatalog() }
        return nil
    }

    /// Clears a kid's logs. Summaries go with them.
    ///
    /// On the admin's own context, not the reader's, so the copy the admin holds
    /// does not keep rows the store no longer has.
    func deleteHistory(for kid: Kid) -> String? {
        kid.deleteHistory()
        let failure = saveLists()
        // The queue is the same kind of derived state as the shelf, and on a
        // device rather than in the store — so it has to be named here or it
        // survives a wipe. Cleared for whichever kid was asked about, active or
        // not.
        playQueues.clear(for: kid.id)
        // The shelf is derived from what was just deleted. Leaving the copy on
        // screen would show a parent their child's activity seconds after being
        // told it was gone.
        if kid.id == self.kid.id {
            recentTrail = []
            discardCurrentPlay()
            historyCleared += 1
        }
        return failure
    }

    /// Clears the logs **and** the kid's favorites and playlists.
    ///
    /// The only thing in the app that removes a child's own work, and it happens
    /// only when a parent asks for it by name.
    func deleteEverything(for kid: Kid) async -> String? {
        kid.deleteEverything()
        let failure = saveLists()
        playQueues.clear(for: kid.id)
        if kid.id == self.kid.id {
            recentTrail = []
            discardCurrentPlay()
            historyCleared += 1
            await refreshLibrary()
        }
        return failure
    }

    // MARK: - The admin's own way in
    //
    // **Nothing a parent does writes to the kid's log.** The activity report is
    // read as a record of what one child did; a parent checking a rule, hearing
    // a track before denying it, or looking at what a search returns is not
    // that, and a report that mixes the two is worse than no report — it puts
    // words in a child's mouth and the parent has no way to tell which rows are
    // theirs.
    //
    // Every admin screen goes through one of the methods below. They are the
    // only ones on this type that reach the catalog or the player without
    // touching ``EventLog``, and any new admin surface belongs here rather than
    // reusing a kid path.

    /// Catalog search with **no policy applied** and nothing logged.
    ///
    /// A parent choosing what to deny has to be able to see it. This is the one
    /// place the engine is deliberately not consulted, and nothing on the kid's
    /// side may call it.
    func searchUnfiltered(term: String, kinds: Set<ItemKind>, limit: Int = 25) async throws
        -> [CatalogItem]
    {
        let page = try await source.search(term: term, kinds: kinds, limit: limit, offset: 0)
        return try await source.resolveAncestry(for: page.items)
    }

    /// The kid's search, run by the parent, **not logged**.
    ///
    /// Filtered by the kid's real policy and by the real engine, because the
    /// whole point is showing a parent what their child would get. It goes
    /// straight to the catalog rather than through
    /// ``searchIncrementally(term:budgets:)``, which is where the logging lives:
    /// a parent typing terms into the admin must not turn up in their child's
    /// report as things the child looked for.
    func previewSearch(
        term: String,
        budgets: [ItemKind: Int] = Session.searchBudgets
    ) async throws -> KindedResults {
        var latest = KindedResults(byKind: [:])
        for try await snapshot in catalog.searchIncrementally(term: term, budgets: budgets) {
            latest = snapshot
        }
        return latest
    }

    /// Plays something for the parent, **not logged**.
    ///
    /// Still asks the engine, and still refuses what the kid could not play —
    /// the admin's job here is to show what the kid's walls actually do, so
    /// bypassing them would make the screen lie. What changes is that no block
    /// is recorded on refusal and no play is recorded on stop.
    ///
    /// The two lines at the end are what make the second half true: with no
    /// origin and the play already marked written, ``logCurrentPlay()`` has
    /// nothing to do whenever this track ends, however it ends.
    func previewPlay(_ item: CatalogItem) async throws {
        let verdict = try await catalog.verdict(for: item)
        if case .blocked(let reason) = verdict {
            throw Refused(reason: BlockReason(reason))
        }

        // Whatever the kid was playing still gets its duration written; that one
        // is theirs.
        logCurrentPlay()

        try await player.play(item)
        playingOrigin = nil
        currentPlayLogged = true
    }

    // MARK: - Apple Music access

    /// Settles authorization, then lets the subscription answer arrive behind
    /// the app rather than in front of it.
    ///
    /// **Authorization is awaited and the subscription is not**, because they
    /// cost nothing alike. Authorization is answered locally in single-digit
    /// milliseconds and decides whether this app can do its job at all. The
    /// subscription is a network round trip to Apple that takes as long as it
    /// takes — measured hanging indefinitely in the simulator — and the whole
    /// app used to sit behind it under a spinner. That is the launch cost:
    /// nothing was wrong, we were waiting for a question whose answer is yes
    /// for every real user of this app.
    ///
    /// So it is assumed yes and checked afterwards. The optimism gives away
    /// nothing: an account that cannot play catalog content still cannot, and
    /// the screen swaps to ``Access/cannotPlay(_:)`` the moment the answer says
    /// so — before a kid can get much further than looking at their shelves,
    /// and nothing they tap in the meantime will produce sound it should not.
    ///
    /// **A failure to reach Apple is not a negative answer**, which is why the
    /// error is dropped rather than shown. Only a definite "this account cannot
    /// play" takes the app down. An offline device leaves the app up and lets
    /// playback fail with its own error, which names the real problem —
    /// ``CatalogError/offline`` — instead of telling a parent their
    /// subscription is the trouble when it is not.
    func start() async {
        let status = await musicAccess.requestAuthorization()
        guard status == .authorized else {
            access = .needsAuthorization(status)
            return
        }

        access = .ready

        guard let subscription = try? await musicAccess.subscriptionState(),
              !subscription.canPlayCatalogContent
        else { return }
        access = .cannotPlay(subscription)
    }

    // MARK: - Searching

    /// How many of each kind one search aims for.
    ///
    /// Three budgets rather than one shared limit, because one shared limit is
    /// how this app ended up song-only without anyone deciding it should be:
    /// the source returns songs first and the cap cut the rest off the end.
    ///
    /// Weighted the way a search is actually read. A handful of artists is
    /// usually the whole useful answer — there is one Taylor Swift — while songs
    /// are the long tail where a kid is scanning for the one they meant.
    static let searchBudgets: [ItemKind: Int] = [.artist: 6, .album: 12, .song: 24]

    // There is deliberately no awaited, logging `search(term:)`. Every kind is
    // fetched in one go and delivered incrementally, so the filter on the
    // results screen is a view onto what is already here rather than a new
    // search — and one search is one logged event, not one per time a kid taps
    // a tab. An awaited convenience wrapper existed and had exactly one caller,
    // the admin's diagnostics screen, which is the one place that must not log
    // at all. Leaving it there was leaving the trap loaded for the next admin
    // screen; ``previewSearch(term:budgets:)`` is what that caller wants.

    /// The kid's search, delivered a kind at a time.
    ///
    /// What the kid's screen uses. The kinds do not cost the same — artists
    /// settle in one request because nothing is filtered out of them, songs page
    /// several times to fill their budget — so awaiting all three makes the tab
    /// the screen opens on wait for the two it is not showing.
    ///
    /// Logging happens exactly once, and **survives the stream being dropped.**
    /// See ``logSearch``.
    func searchIncrementally(
        term: String,
        budgets: [ItemKind: Int] = Session.searchBudgets
    ) -> AsyncThrowingStream<KindedResults, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var latest = KindedResults(byKind: [:])

                // `byKind` non-empty is what "the kid settled on this term"
                // actually means, and it is the test both exits below apply. A
                // term replaced by more typing before any kind landed was never
                // a search from the kid's point of view and stays out of the
                // report, which is the trade this file always intended. A term
                // whose results reached the screen is a search they made,
                // whether or not the remaining kinds ever arrived.

                do {
                    for try await snapshot in catalog.searchIncrementally(
                        term: term, budgets: budgets
                    ) {
                        latest = snapshot
                        continuation.yield(snapshot)
                    }
                } catch {
                    // Cancellation is not a failure, it is a teardown, and it is
                    // the common case: artists land first and the screen shows
                    // results while songs are still paging, so anything that
                    // ends the search — tapping into a result, the field
                    // clearing, a parent opening the admin to go and read the
                    // report — arrives mid-flight. Logging only on a clean run
                    // meant those searches were never recorded at all, which is
                    // the one thing the report cannot afford to be missing.
                    if Task.isCancelled {
                        if !latest.byKind.isEmpty { logSearch(term: term, results: latest) }
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                // Cancellation can also end the inner stream without throwing.
                if !latest.byKind.isEmpty { logSearch(term: term, results: latest) }
                continuation.finish()
            }
            // A kid typing a second term over the first drops this stream, and
            // dropping it has to stop the requests behind it rather than leave
            // them running to fill a page nobody is waiting on any more.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Writes the search and everything it filtered out.
    ///
    /// Blocked results are logged even though the kid never saw them. They are
    /// the most useful line in a parent's report: they are how a parent finds
    /// out what their kid is curious about.
    ///
    /// **Once per term the kid settled on** — not once per kind, which would
    /// make one thing a kid did read as three searches in the report.
    ///
    /// "Settled on" means results for it reached the screen, not that every kind
    /// finished. A kid who retypes fast enough that nothing landed leaves no
    /// record of the first term, which is the right trade: a half-typed term
    /// they replaced themselves is noise. But a term whose results they *saw* is
    /// a search they made, and it is recorded even though the stream was torn
    /// down before the slower kinds arrived — which is what happens every time
    /// someone taps into a result, or opens the admin to go and read the report.
    ///
    /// The cost, stated because it is real: a torn-down search logs the counts of
    /// the kinds that had landed, so `resultCount` and `blockedCount` understate
    /// a search nobody waited out. A row with slightly low counts is worth far
    /// more to a parent than no row at all.
    private func logSearch(term: String, results: KindedResults) {
        eventLog.log(
            SearchEvent(
                term: term,
                resultCount: results.items.count,
                blockedCount: results.blocked.count,
                gaveUpEarly: results.gaveUpEarly
            ),
            for: kid.id
        )

        for blocked in results.blocked {
            // Filtered out before the page was drawn: the kid never saw these
            // and did nothing. Most of the block table is this.
            log(
                blocked.item,
                blockedFor: BlockReason(blocked.reason),
                reach: .unseen,
                origin: .search(term: term)
            )
        }
    }

    // MARK: - Playing

    /// Refused at the moment of playback, carrying why.
    struct Refused: Error {
        let reason: BlockReason
    }

    private var playingOrigin: PlaybackOrigin?

    /// Guards against writing the same play twice.
    ///
    /// A play is flushed from several places now — the track ending, a skip,
    /// starting something else, the app going to the background — because the
    /// kid's controls are play, pause and skip, and none of those is a "stop"
    /// that could own the job alone.
    private var currentPlayLogged = true

    /// Plays one item, **asking the policy engine again first**.
    ///
    /// It asks again rather than trusting that the UI only offered allowed
    /// things. A UI that shows something the player then refuses is a UI bug,
    /// not a safety failure — and this is the check that makes that true.
    func play(_ item: CatalogItem, origin: PlaybackOrigin) async throws {
        let verdict = try await catalog.verdict(for: item)

        if case .blocked(let reason) = verdict {
            let blockReason = BlockReason(reason)
            // They pressed play. One of the few block rows that describes
            // something the child actually did.
            log(item, blockedFor: blockReason, reach: .reached, origin: origin)
            throw Refused(reason: blockReason)
        }

        // Whatever was playing ends here, so its duration is known.
        logCurrentPlay()

        try await player.play(item)
        playingOrigin = origin
        currentPlayLogged = false

        // After the audio is running, not before: this is the shelf catching up
        // with the kid, and nothing about it should delay the sound.
        await noteVisit(item, manner: .played)
    }

    /// Records that the kid got to something, and takes the new shelf back.
    ///
    /// **Awaited, unlike ``EventLog``**, and the asymmetry is the point. A
    /// dropped log line costs a report a line; a home screen that does not
    /// change when a kid presses play reads as the tap having done nothing. It
    /// is a local insert on a background actor, on a path that already awaits a
    /// network round trip for the verdict.
    ///
    /// The trail comes back *from the write*. A caller that wrote and then
    /// fetched would be racing its own write — which is exactly the bug the
    /// Recent shelf had: the home screen reloaded microseconds after the write
    /// was handed to a detached task, usually before the row committed.
    ///
    /// On failure the trail is left alone rather than guessed at. The next
    /// arrival converges; a shelf that disagrees with the store would not.
    func noteVisit(_ item: CatalogItem, manner: VisitManner) async {
        let kidID = kid.id
        let visit = VisitEvent(
            itemID: item.id,
            displayName: item.title,
            artworkURL: item.artworkURL,
            albumID: item.ancestors.first { $0.id.kind == .album }?.id,
            artistID: item.ancestors.first { $0.id.kind == .artist }?.id,
            rating: StoredRating(item.rating),
            manner: manner
        )

        guard let trail = try? await recents.record(visit, for: kidID) else { return }
        // A parent can switch kids while this is in flight, and one child's
        // shelf must not land on another's screen.
        guard kidID == kid.id else { return }
        recentTrail = trail
    }

    func resume() async throws {
        try await player.resume()
    }

    /// Fetches what the next track will need while this one is still playing.
    ///
    /// **Nothing here is a decision.** No verdict is asked and none is cached:
    /// this warms a catalog fetch, and ``play(_:origin:)`` still judges the item
    /// immediately before any sound comes out of it. That ordering is what keeps
    /// a parent's deny landing mid-song from being defeated by a song that had
    /// already been fetched.
    ///
    /// Nothing is logged either. A preload is the app getting ready, not the
    /// child reaching anything — a visit is recorded when a track starts, which
    /// is the moment they actually hear it.
    func preload(_ item: CatalogItem) async {
        await player.preload(item)
    }

    // MARK: - The handover
    //
    // Where the policy check moved to, and what it costs.
    //
    // Two tracks only join without a gap if the player is holding the second one
    // before the first ends, which means it advances once without being asked —
    // the thing ``KidPlayerModel`` was built to prevent. The check did not go
    // away; it moved earlier, and moving it earlier opens a window in which a
    // parent's deny can land after a song was judged and before it is heard.
    //
    // Three things keep that window as small as it can be made:
    //
    // 1. The insertion happens late — seconds before the handover, not at the
    //    start of the previous track. See `KidPlayerModel.enqueueLead`.
    // 2. The verdict is re-taken on every poll for as long as the song sits
    //    there, and a changed answer pulls it straight back out.
    // 3. The song is judged once more the instant the player moves to it, and a
    //    refusal cuts the audio.
    //
    // What is left is the time between the last poll before the handover and the
    // handover itself. It is not zero, and nothing in this design makes it zero;
    // it is a fraction of a second of a song a parent denied moments earlier.

    /// Judges an item and, if it passes, puts it behind what is playing.
    ///
    /// Nothing is logged on a refusal, deliberately. The kid has not reached
    /// anything — this is the app looking ahead — and the block will be recorded
    /// properly by ``play(_:origin:)`` if and when the queue actually gets
    /// there. Logging here as well would put two rows in the report for one
    /// song, and the earlier of the two would describe something that never
    /// happened.
    ///
    /// Returns whether the song was queued.
    @discardableResult
    func enqueueNext(_ item: CatalogItem) async -> Bool {
        guard let verdict = try? await catalog.verdict(for: item), verdict.isAllowed else {
            return false
        }
        do {
            try await player.enqueueNext(item)
        } catch {
            return false
        }
        return player.nextUp?.id == item.id
    }

    /// What the engine says about a song that is already queued.
    ///
    /// Three states rather than a boolean, for the reason a rating is three
    /// states rather than a boolean: "we could not say" is not "no", and a
    /// report that writes it down as one is showing a parent our gap as their
    /// child's music.
    enum QueuedVerdict {
        case allowed
        case blocked(BlockReason)

        /// Not answerable without going to the network, which this call will not
        /// do. The caller drops the song from the queue — a guess is not good
        /// enough to leave one there on — and the ordinary play path judges it
        /// properly a moment later.
        case unknown
    }

    /// Re-asks the engine about the song already queued.
    ///
    /// Synchronous and free of I/O, because it runs on every poll: an item that
    /// reached the queue carries its ancestry, so this is the engine's own
    /// indexed lookup and nothing more.
    func queuedVerdict(for item: CatalogItem) -> QueuedVerdict {
        guard !item.ancestors.isEmpty else { return .unknown }
        switch kid.makeEngine().evaluate(item.policyItem) {
        case .allowed: return QueuedVerdict.allowed
        case .blocked(let reason): return QueuedVerdict.blocked(BlockReason(reason))
        }
    }

    /// Pulls the queued song back out. What a changed verdict turns into.
    func cancelNext() {
        player.cancelNext()
    }

    /// Takes over the track the player advanced to on its own.
    ///
    /// The previous track's play event must already have been flushed — this
    /// changes what `nowPlaying` is, and ``logCurrentPlay()`` reads it.
    func adoptNext(origin: PlaybackOrigin) -> CatalogItem? {
        guard let adopted = player.adoptNext() else { return nil }
        playingOrigin = origin
        currentPlayLogged = false
        return adopted
    }

    /// Refuses a track the player had already started.
    ///
    /// The one path where a block is logged for something the kid *heard* rather
    /// than something they asked for, which is why it is `reached`: a fraction
    /// of a second of it came out of the speaker before this ran, and that is
    /// the honest record of what happened. The play in progress is thrown away
    /// rather than written — a refused track is not a listen.
    func refuseAdopted(_ item: CatalogItem, reason: BlockReason, origin: PlaybackOrigin) {
        discardCurrentPlay()
        log(item, blockedFor: reason, reach: .reached, origin: origin)
    }

    // MARK: - The kid's surfaces

    /// What the home screen shows.
    ///
    /// Level 1 is the allow list itself — that *is* the reachable catalogue.
    /// Levels 2 and 3 show the trail: songs, albums and artists mixed, whatever
    /// the kid last got to. It is only useful because it is **filtered at render
    /// time** rather than kept as a stored list of allowed things — a kid's
    /// recents can contain something a parent has denied since, and a stale list
    /// would leave it sitting on the home screen looking tappable.
    ///
    /// The limit is applied **after** filtering, not before. Taking it first is
    /// how the shelf used to come back short, or empty, with plenty of eligible
    /// history behind it: a denied artist near the front of the trail ate one of
    /// the twenty-four slots and nothing topped it up.
    func homeItems(limit: Int = 24) async throws -> [CatalogItem] {
        let allowed = try await resolveAllowed(recentTrail.map(\.catalogID))
        return Array(allowed.prefix(limit))
    }

    /// The allow list, resolved. What a level 1 home shows below its recents,
    /// and the whole of the reachable catalogue at that level.
    func allowListItems() async throws -> [CatalogItem] {
        let ids = kid.entries.compactMap { $0.entry }.filter { $0.kind == .allow }.map(\.id)
        return try await resolveAllowed(ids)
    }

    /// The allow list where the level shows one, and nothing where it does not.
    ///
    /// The empty answer is a policy answer, not a view's shortcut, which is why
    /// it is here: levels 2 and 3 have an allow list and simply do not put it on
    /// the home screen, so "which level shows this shelf" is a question about
    /// the sandbox rather than about layout. It also lets the home screen start
    /// all three of its fetches together — a branch in the caller would have to
    /// be resolved before any of them began.
    func grownUpItems() async throws -> [CatalogItem] {
        kid.mode == .allowOnly ? try await allowListItems() : []
    }

    // There is deliberately no kid-facing play history any more. It read
    // `PlayEventRecord` — written on stop, five-second floor, songs only —
    // while the shelf above it read arrivals, so the screen behind the "Recent"
    // chevron showed a different list from the shelf that led to it. One of the
    // two had to go, and the one a kid means by "recent" is where they have
    // been. Play events are untouched and still carry the report: duration,
    // listening time, top songs. They are a parent's question, not a shelf.

    /// Every arrival, newest first, a page at a time.
    ///
    /// **What the Recent shelf is a summary of.** The shelf collapses a run
    /// through one record into the record and drops an artist whose work is
    /// already on it; this is the same stream with none of that applied, which
    /// is what makes the shelf and the screen behind it agree — one is the other
    /// with the grouping taken off, rather than a different list built from a
    /// different table.
    ///
    /// Filtered at render time like everything else, so something denied since
    /// is absent.
    ///
    /// **One row per item, at the most recent time it was reached.** A kid who
    /// opened one record five times running produced five arrivals and wants one
    /// row; more to the point, a list cannot draw the same thing twice — two
    /// rows sharing a `CatalogItem` identity give SwiftUI duplicate ids in a
    /// `ForEach`, and what it draws for the loser is a blank the height of a row
    /// with the separators still around it. That is not a hypothetical: it is
    /// what this screen did.
    ///
    /// Deduplicated *before* resolving, so a page of forty-eight arrivals
    /// through one record costs one lookup rather than forty-eight.
    func recentEvents(page: Int, pageSize: Int = 48) async throws
        -> (items: [CatalogItem], hasMore: Bool)
    {
        let kidID = kid.id
        var descriptor = FetchDescriptor<VisitEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        descriptor.fetchLimit = pageSize
        descriptor.fetchOffset = page * pageSize

        guard let rows = try? ModelContext(container).fetch(descriptor) else { return ([], false) }

        var seen: Set<CatalogID> = []
        let ids = rows.compactMap(\.event).map(\.itemID).filter { seen.insert($0).inserted }

        // `hasMore` is about the rows behind the page, not the items in front of
        // it: collapsing repeats can empty a page that had plenty in it, and
        // stopping there would hide everything older.
        return (try await resolveAllowed(ids), rows.count == pageSize)
    }

    /// Resolves identifiers to items and drops everything this kid may not see.
    ///
    /// Ancestry is resolved in one batch before anything is judged, so a song
    /// whose artist was denied is caught here rather than becoming a tile that
    /// refuses when tapped.
    func resolveAllowed(_ ids: [CatalogID]) async throws -> [CatalogItem] {
        guard !ids.isEmpty else { return [] }
        let items = try await source.items(for: ids)
        let resolved = try await source.resolveAncestry(for: items)
        let engine = kid.makeEngine()
        return resolved.filter { engine.evaluate($0.policyItem).isAllowed }
    }

    /// What is inside an artist or album, filtered.
    func children(of id: CatalogID) async throws -> FilteredResults {
        try await catalog.children(of: id)
    }

    /// An artist's best-known songs, filtered.
    func topSongs(of id: CatalogID) async throws -> FilteredResults {
        try await catalog.topSongs(of: id)
    }

    /// Who made this, as items a screen can link to — and only the ones this kid
    /// is allowed to reach.
    func artists(of id: CatalogID) async throws -> [CatalogItem] {
        try await catalog.artists(of: id)
    }

    // MARK: - The kid's library
    //
    // Everything here goes through ``MergedLibrary``. Nothing on this side names
    // a provider, learns that one failed, or discovers that one cannot do
    // something — those are admin-facing and this is the kid's app.

    func isFavorite(_ id: CatalogID) -> Bool { favoriteIDs.contains(id) }

    // MARK: - The shared-device question

    /// Whether anyone has answered it yet. Onboarding puts the question while
    /// this is false, and nothing is read from the Apple Music library until it
    /// is true — see ``DeviceLibraryState/hasBeenAsked``.
    var hasAnsweredSharedDevice: Bool { deviceLibrary.hasBeenAsked }

    /// Records both answers, from onboarding or from the admin.
    ///
    /// **Both call sites mark it answered**, which is the point. A parent who
    /// reaches the switches in the admin has been asked as surely as one who
    /// answered at first launch, and treating the two differently would leave a
    /// device where the question was settled and the gate still shut.
    ///
    /// Changing them later loses nothing. Becoming the kid's own library adopts
    /// what is in it from that point rather than backfilling anything; ceasing
    /// to be one stops reading and writing there and leaves every row we hold.
    func setDeviceAnswers(sharesDevice: Bool, childHasOwnAccount: Bool) {
        deviceLibrary = DeviceLibraryState(
            sharesDeviceWithChild: sharesDevice,
            childHasOwnAccount: childHasOwnAccount,
            hasBeenAsked: true
        )
        deviceLibraryStore.save(deviceLibrary)
        // Which providers are live may have just changed, so what the shelves
        // draw from has too.
        Task { await refreshLibrary() }
    }

    /// Fills or empties the heart. Returns a message on failure, `nil` on
    /// success — the same contract a parent's list edit keeps, and for the same
    /// reason: a heart that fills over a write that did not land is a lie.
    ///
    /// A refusal is **not** a failure to report. The engine turned it down, the
    /// block goes to the parent's report, and the kid is told nothing: the item
    /// was on their screen because a policy edit landed between the draw and the
    /// tap, and there is nothing they did wrong to explain.
    func toggleFavorite(_ item: CatalogItem, origin: PlaybackOrigin) async -> String? {
        do {
            if isFavorite(item.id) {
                try await library.removeFavorite(item.id)
            } else {
                try await library.addFavorite(item)
            }
        } catch let refusal as LibraryRefused {
            // They tapped the heart.
            log(
                refusal.item,
                blockedFor: BlockReason(refusal.reason),
                reach: .reached,
                origin: origin
            )
            await refreshLibrary()
            return nil
        } catch {
            return Self.message(for: error)
        }
        await refreshLibrary()
        return nil
    }

    /// Re-reads what the heart and the shelves draw from.
    ///
    /// Cheap by construction: rows are already in memory and the catalog is not
    /// consulted, which is why it is safe to call after every write.
    func refreshLibrary() async {
        favoriteIDs = await library.favoriteIDs()
        playlists = await library.playlists()
    }

    /// The "Library" shelf: every favorite this kid may still see.
    ///
    /// **The blocked half is deliberately not logged here**, which is the one
    /// place in the app that is true. Everywhere else a block is a transient
    /// result of something a kid just did — a search, a browse — and logging it
    /// is the only way it survives to reach a parent. A blocked favorite is a
    /// stored row that is still there, so the report can find it whenever it is
    /// asked. Logging on every redraw would write the same block once per home
    /// screen appearance and drown the report in it.
    func favoriteItems() async throws -> [CatalogItem] {
        try await library.favorites().items
    }

    /// One playlist's songs, in the order the kid put them in. Blocks are not
    /// logged, for the same reason.
    func playlistSongs(_ handle: PlaylistHandle) async throws -> [CatalogItem] {
        try await library.songs(in: handle).items
    }

    /// A local predicate over the kid's own rows. Never a catalog search, and
    /// never `MusicLibrarySearchRequest`.
    func searchLibrary(_ term: String) async throws -> [CatalogItem] {
        try await library.searchLibrary(term).items
    }

    func createPlaylist(named name: String, songs: [CatalogItem] = []) async -> String? {
        await libraryEdit { try await self.library.createPlaylist(named: name, songs: songs) }
    }

    func addToPlaylist(_ handle: PlaylistHandle, song: CatalogItem, origin: PlaybackOrigin) async
        -> String?
    {
        do {
            try await library.addToPlaylist(handle, song: song)
        } catch let refusal as LibraryRefused {
            // They added it to a playlist.
            log(
                refusal.item,
                blockedFor: BlockReason(refusal.reason),
                reach: .reached,
                origin: origin
            )
            return nil
        } catch {
            return Self.message(for: error)
        }
        await refreshLibrary()
        return nil
    }

    func removeFromPlaylist(_ handle: PlaylistHandle, song: CatalogID) async -> String? {
        await libraryEdit { try await self.library.removeFromPlaylist(handle, song: song) }
    }

    func reorderPlaylist(_ handle: PlaylistHandle, to order: [CatalogID]) async -> String? {
        await libraryEdit { try await self.library.reorderPlaylist(handle, to: order) }
    }

    func renamePlaylist(_ handle: PlaylistHandle, to name: String) async -> String? {
        await libraryEdit { try await self.library.renamePlaylist(handle, to: name) }
    }

    func deletePlaylist(_ handle: PlaylistHandle) async -> String? {
        await libraryEdit { try await self.library.deletePlaylist(handle) }
    }

    /// Runs one library write and refreshes what the screens read.
    private func libraryEdit(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
        } catch {
            return Self.message(for: error)
        }
        await refreshLibrary()
        return nil
    }

    func stop() async {
        logCurrentPlay()
        try? await player.stop()
        playingOrigin = nil
    }

    /// Writes the play event for whatever is loaded, if it ran long enough.
    ///
    /// Duration is the signal, so this happens on stop rather than on start.
    /// `EventLog` drops anything under five seconds — a mis-tap is not a listen.
    /// Writes the play for whatever is loaded, if it has not been written yet.
    ///
    /// Safe to call from anywhere and as often as you like — the flag is what
    /// makes it idempotent, and every caller would otherwise have to know
    /// whether one of the others got there first.
    func flushCurrentPlay() {
        logCurrentPlay()
    }

    /// Throws the play in progress away instead of writing it.
    ///
    /// The one caller is a history wipe, and it is the only place discarding is
    /// right. The song a kid is in the middle of when a parent clears the logs
    /// is part of what was cleared, and stopping the player afterwards would
    /// otherwise write it straight back — a report that comes back with one row
    /// in it seconds after being emptied.
    private func discardCurrentPlay() {
        currentPlayLogged = true
    }

    private func logCurrentPlay() {
        guard !currentPlayLogged, let item = player.nowPlaying, let origin = playingOrigin
        else { return }
        currentPlayLogged = true

        eventLog.log(
            PlayEvent(
                songID: item.id,
                albumID: item.ancestors.first { $0.id.kind == .album }?.id,
                artistID: item.ancestors.first { $0.id.kind == .artist }?.id,
                displayName: item.title,
                // Recorded so the parent's report can re-judge this row offline.
                // Without it every play of a level 2 kid's week reads back as
                // unrated-and-therefore-blocked.
                rating: StoredRating(item.rating),
                secondsPlayed: player.playbackSeconds,
                origin: origin
            ),
            for: kid.id
        )
    }

    /// Logs a whole filtered-out batch.
    ///
    /// Every block is recorded, including ones the kid never saw. They are the
    /// most useful line in a parent's report: they are how a parent finds out
    /// what their kid went looking for.
    func logBlocked(_ blocked: [BlockedItem], origin: PlaybackOrigin) {
        for item in blocked {
            log(item.item, blockedFor: BlockReason(item.reason), reach: .unseen, origin: origin)
        }
    }

    /// Writes one block.
    ///
    /// **`reach` has no default**, deliberately. It is the one field on a block
    /// that describes the child rather than the item, and the two paths into
    /// here are otherwise indistinguishable: a result filtered out of a page the
    /// kid never saw carries the same identifier, reason and origin as a song
    /// they pressed play on. A default would let a call site forget which of
    /// those it is, and the parent's report would read intent into our own
    /// filter. See ``BlockReach``.
    private func log(
        _ item: CatalogItem,
        blockedFor reason: BlockReason,
        reach: BlockReach,
        origin: PlaybackOrigin
    ) {
        eventLog.log(
            BlockEvent(
                itemID: item.id,
                displayName: item.title,
                artistID: item.ancestors.first { $0.id.kind == .artist }?.id,
                rating: StoredRating(item.rating),
                reach: reach,
                reason: reason,
                origin: origin
            ),
            for: kid.id
        )
    }

    // MARK: - Policy

    func setMode(_ mode: SandboxMode) {
        kid.setMode(mode)
        try? context.save()
        rebuildCatalog()
    }

    func setUnratedBehavior(_ behavior: UnratedBehavior) {
        kid.setUnratedBehavior(behavior)
        try? context.save()
        rebuildCatalog()
    }

    /// Adds a deny, awaited, with the failure returned rather than swallowed.
    ///
    /// The opposite contract to event logging: a parent who denies something and
    /// gets silence must not be left believing it landed.
    /// Takes an identifier rather than an item so a song's *artist* can be
    /// denied from a list of songs. Denying the thing in front of you is the
    /// easy half; reaching its container is the half that proves ancestry
    /// resolved, and the half a parent actually wants.
    func deny(_ id: CatalogID, displayName: String, artworkURL: URL? = nil) -> String? {
        addEntry(kind: .deny, id: id, displayName: displayName, artworkURL: artworkURL)
    }

    func addEntry(
        kind: PolicyEntry.Kind,
        id: CatalogID,
        displayName: String,
        artworkURL: URL? = nil
    ) -> String? {
        kid.addEntry(
            kind: kind,
            id: id,
            displayName: displayName,
            artworkURL: artworkURL
        )
        do {
            try context.save()
        } catch {
            return error.localizedDescription
        }
        rebuildCatalog()
        return nil
    }

    /// Removes one rule. Awaited and surfaced, like adding one.
    func removeEntry(_ record: PolicyEntryRecord) -> String? {
        kid.removeEntry(record)
        return saveLists()
    }

    /// Removes every rule pointing at this identifier.
    ///
    /// Every, not the first: nothing stops a list holding two rows for the same
    /// item, and leaving one behind would look like the undo silently failed.
    func removeEntries(matching id: CatalogID) -> String? {
        for record in kid.entries.filter({ $0.entry?.id == id }) {
            kid.removeEntry(record)
        }
        return saveLists()
    }

    private func saveLists() -> String? {
        do {
            try context.save()
        } catch {
            return error.localizedDescription
        }
        rebuildCatalog()
        return nil
    }

    /// Rebuilds everything that holds a policy engine.
    ///
    /// Both, always. A policy edit that reached the catalog but not the library
    /// would leave a denied artist off search results and still on the kid's
    /// shelf — the one screen a parent is least likely to check.
    private func rebuildCatalog() {
        catalog = FilteredCatalog(source: source, engine: kid.makeEngine())
        library = MergedLibrary(
            providers: [CloudKitLibraryProvider(kid: kid, context: context)],
            catalog: source,
            engine: kid.makeEngine(),
            device: deviceLibraryStore
        )
        // The heart and the shelves read from a different kid's rows now, or from
        // the same kid's under a new policy. Neither is what is on screen.
        Task { await refreshLibrary() }
    }

    static func message(for error: any Error) -> String {
        (error as? CatalogError)?.errorDescription ?? error.localizedDescription
    }
}
