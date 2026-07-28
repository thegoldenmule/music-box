import AdminGate
import CatalogKit
import FamilyStore
import Foundation
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
    enum Access {
        case checking
        case needsAuthorization(AuthorizationStatus)
        case cannotPlay(SubscriptionState)
        case ready
        case failed(String)
    }

    private(set) var access: Access = .checking

    let container: ModelContainer
    let eventLog: EventLog
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

    private let family: Family
    private let context: ModelContext
    private let musicAccess = MusicKitAccess()
    private let source: any CatalogSource

    init(passcodes: any PasscodeStore = KeychainPasscodeStore()) throws {
        container = try FamilyStore.container()
        context = ModelContext(container)
        eventLog = EventLog(modelContainer: container)
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
        kids = family.kids
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

    func switchTo(_ kid: Kid) {
        self.kid = kid
        rebuildCatalog()
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
        family.removeKid(kid)
        context.delete(kid)
        let failure = saveLists()
        kids = family.kids
        if wasActive, let first = family.kids.first {
            switchTo(first)
        }
        return failure
    }

    // MARK: - Unfiltered search, for the admin only

    /// Catalog search with **no policy applied**.
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

    // MARK: - Apple Music access

    func start() async {
        let status = await musicAccess.requestAuthorization()
        guard status == .authorized else {
            access = .needsAuthorization(status)
            return
        }

        do {
            let subscription = try await musicAccess.subscriptionState()
            access = subscription.canPlayCatalogContent ? .ready : .cannotPlay(subscription)
        } catch {
            access = .failed(Self.message(for: error))
        }
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

    /// Searches, and logs what came back — including everything filtered out.
    ///
    /// Blocked results are logged even though the kid never saw them. They are
    /// the most useful line in a parent's report: they are how a parent finds
    /// out what their kid is curious about.
    ///
    /// Every kind is fetched in one go, so the filter on the results screen is a
    /// view onto what is already here rather than a new search. That keeps
    /// switching instant, and it keeps the parent's report honest: one search is
    /// one logged event, not one per time a kid taps a tab.
    func search(
        term: String,
        budgets: [ItemKind: Int] = Session.searchBudgets
    ) async throws -> KindedResults {
        var latest = KindedResults(byKind: [:])
        for try await snapshot in searchIncrementally(term: term, budgets: budgets) {
            latest = snapshot
        }
        return latest
    }

    /// The same search, delivered a kind at a time.
    ///
    /// What the kid's screen uses. The kinds do not cost the same — artists
    /// settle in one request because nothing is filtered out of them, songs page
    /// several times to fill their budget — so awaiting all three makes the tab
    /// the screen opens on wait for the two it is not showing.
    ///
    /// Logging still happens exactly once, at the end. See ``logSearch``.
    func searchIncrementally(
        term: String,
        budgets: [ItemKind: Int] = Session.searchBudgets
    ) -> AsyncThrowingStream<KindedResults, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var latest = KindedResults(byKind: [:])
                do {
                    for try await snapshot in catalog.searchIncrementally(
                        term: term, budgets: budgets
                    ) {
                        latest = snapshot
                        continuation.yield(snapshot)
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                logSearch(term: term, results: latest)
                continuation.finish()
            }
            // A kid typing a second term over the first drops this stream, and
            // dropping it has to stop the requests behind it rather than leave
            // them running to log a term nobody is waiting on any more.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Writes the search and everything it filtered out.
    ///
    /// Blocked results are logged even though the kid never saw them. They are
    /// the most useful line in a parent's report: they are how a parent finds
    /// out what their kid is curious about.
    ///
    /// **Once, when every kind is in** — not once per kind, which would make one
    /// thing a kid did read as three searches in the report, and not on a search
    /// that threw or was cancelled, where the counts would be of a page that was
    /// never finished. The cost is that a kid who retypes fast enough to cancel
    /// leaves no record of the first term. That is the right trade: the report is
    /// read as a record of what a kid looked for, and a half-typed term they
    /// replaced themselves is noise in it.
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
            log(blocked.item, blockedFor: BlockReason(blocked.reason), origin: .search(term: term))
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
            log(item, blockedFor: blockReason, origin: origin)
            throw Refused(reason: blockReason)
        }

        // Whatever was playing ends here, so its duration is known.
        logCurrentPlay()

        try await player.play(item)
        playingOrigin = origin
        currentPlayLogged = false
    }

    func resume() async throws {
        try await player.resume()
    }

    // MARK: - The kid's surfaces

    /// What the home screen shows.
    ///
    /// Level 1 is the allow list itself — that *is* the reachable catalogue.
    /// Levels 2 and 3 show what was played recently, which is only useful
    /// because it is **filtered at render time** rather than kept as a stored
    /// list of allowed things: a kid's recents can contain something a parent
    /// has denied since, and a stale list would leave it sitting on the home
    /// screen looking tappable.
    func homeItems(limit: Int = 24) async throws -> [CatalogItem] {
        try await resolveAllowed(recentlyPlayed(limit: limit))
    }

    /// The allow list, resolved. What a level 1 home shows below its recents,
    /// and the whole of the reachable catalogue at that level.
    func allowListItems() async throws -> [CatalogItem] {
        let ids = kid.entries.compactMap { $0.entry }.filter { $0.kind == .allow }.map(\.id)
        return try await resolveAllowed(ids)
    }

    /// One page of everything this kid has played, most recent first.
    ///
    /// **Filtered at render time, like recents**, which means it is a history of
    /// what they played *and may still play*. Something denied since is absent.
    /// The alternative — showing it greyed out — puts a thing a kid can see and
    /// cannot touch on their own screen, which is the invitation to ask why that
    /// the whole design avoids.
    ///
    /// Filtering after paging means a page can come back short. It over-fetches
    /// for the same reason search does, and `hasMore` is about the *source*
    /// running out, not about the page being full.
    func playHistory(page: Int, pageSize: Int = 24) async throws
        -> (items: [CatalogItem], hasMore: Bool)
    {
        let raw = recentlyPlayed(limit: pageSize * 3, offset: page * pageSize * 3)
        let items = try await resolveAllowed(raw)
        return (items, raw.count == pageSize * 3)
    }

    /// Distinct songs this kid played, most recent first.
    ///
    /// **Fetched on a fresh context, not read off `kid.plays`.** Events are
    /// written by ``EventLog``, which is a `@ModelActor` with its own context —
    /// that is the whole point of it, so logging never blocks playback. The
    /// consequence is that this context's already-materialised `plays`
    /// relationship does not see those rows, and reading it returns an empty
    /// list forever no matter how much the kid listens to. A context created
    /// here reads what has actually been committed.
    private func recentlyPlayed(limit: Int, offset: Int = 0) -> [CatalogID] {
        let kidID = kid.id
        var descriptor = FetchDescriptor<PlayEventRecord>(
            predicate: #Predicate { $0.kid?.id == kidID },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        // Over-fetch: the same song played five times is one tile, and the
        // dedupe happens after the sort.
        descriptor.fetchLimit = limit * 4
        descriptor.fetchOffset = offset

        guard let rows = try? ModelContext(container).fetch(descriptor) else { return [] }

        var seen = Set<String>()
        return
            rows
            .compactMap { seen.insert($0.songID).inserted ? CatalogID(.song, $0.songID) : nil }
            .prefix(limit)
            .map { $0 }
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
            log(item.item, blockedFor: BlockReason(item.reason), origin: origin)
        }
    }

    private func log(_ item: CatalogItem, blockedFor reason: BlockReason, origin: PlaybackOrigin) {
        eventLog.log(
            BlockEvent(
                itemID: item.id,
                displayName: item.title,
                artistID: item.ancestors.first { $0.id.kind == .artist }?.id,
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

    private func rebuildCatalog() {
        catalog = FilteredCatalog(source: source, engine: kid.makeEngine())
    }

    static func message(for error: any Error) -> String {
        (error as? CatalogError)?.errorDescription ?? error.localizedDescription
    }
}
