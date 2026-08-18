import AdminGate
import CatalogKit
import FamilyStore
import FamilySync
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

    /// Every grown-up in the family, in the order they were added. Often empty,
    /// which is a working state and not an unfinished one — see ``GrownUp``.
    private(set) var grownUps: [GrownUp] = []

    /// Which of them is at the keyboard on this device.
    ///
    /// A mirror of ``actingGrownUpStore`` resolved against the roster, held here
    /// so the admin's checkmark redraws. **Nothing reads it to decide what a kid
    /// may reach** — it names who is curating, and only so their name lands on
    /// what they curate.
    ///
    /// `nil` whenever the roster is empty, and also when the stored identifier
    /// names somebody who has since been removed. Both fall back the same way:
    /// writes stamp nothing and shelves read as they did before anyone was named.
    private(set) var actingGrownUp: GrownUp?

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

    /// Live suggestions, newest first. What the parent's shelf draws from.
    ///
    /// Held for the reason ``playlists`` is: the expanded shelf and the detail
    /// screen behind a suggested playlist are pushed views, rebuilt from a route
    /// every time the stack changes, and one that fetched on appearance would
    /// put a spinner between a tap and a list already in memory.
    ///
    /// **Not policy filtered.** These are stored rows and the tiles are judged at
    /// render time by ``suggestionItems()``, the same arrangement the Recent
    /// trail has — with the twist that a live suggestion is itself part of what
    /// the engine is judging with.
    private(set) var suggestions: [SuggestionRow] = []

    /// What the kid passed on. The parent's side of the shelf, and the only
    /// place in the app a dismissal is visible.
    private(set) var dismissedSuggestions: [SuggestionRow] = []

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

    /// Sending and accepting invitations.
    ///
    /// Behind a protocol for the reason ``CatalogSource`` is: the admin screen
    /// and its copy have to be reachable with no account and no network, and
    /// the only part that genuinely needs a device is the implementation.
    /// **One provider, shared by both, and that is not a tidiness argument.**
    /// The sharing layer and the sync engine each need to know whether this
    /// device owns the household or joined one, and two caches can disagree:
    /// accepting an invitation invalidates the one it went through and leaves
    /// the other still answering `.owner`, which is exactly the state where
    /// writes go to the wrong database.
    /// Which child this device opens into. See ``resolveBinding()``.
    ///
    /// **`.unenrolled` until resolved**, which is the honest starting value:
    /// nothing has been read yet, and it is the state that runs setup rather
    /// than one that opens a player.
    private(set) var binding: BindingOutcome = .unenrolled

    /// Set only when the device could not resolve *at all* — a Keychain it
    /// cannot read. Distinct from a lock, which is an answer.
    private(set) var bindingTrouble: String?

    /// This device's row in the household roster, once it has one.
    private(set) var deviceRow: DeviceRecord?

    private(set) var signedInAccount: AccountState = .noOpinion

    /// This device's own identifier, minted into the Keychain on first read.
    /// Never derived from the hardware — see ``DeviceIdentityStore``.
    @ObservationIgnored let deviceIdentity: any DeviceIdentityStore = KeychainDeviceIdentity()

    @ObservationIgnored let accountIdentity: any AccountIdentitySource = CloudKitAccountIdentity()

    /// This household's identifier, for a record that points at it by id rather
    /// than by relationship — see ``DeviceRecord``.
    var householdID: UUID { family.id }

    /// This device's row in the roster, if it has been enrolled.
    ///
    /// Here rather than in `SessionBinding.swift` only because `context` is
    /// private to this file, and it should stay that way: a view reaching the
    /// model context directly is how writes end up somewhere nothing can find
    /// them. The *decisions* about enrolment are all in the other file.
    func deviceRecord(id: UUID) -> DeviceRecord? {
        var descriptor = FetchDescriptor<DeviceRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Every device enrolled in this household, for the roster a parent reads.
    ///
    /// **Fetched on demand and never cached.** What changes it is another device
    /// syncing, not anything happening here — so a held copy would be stale in
    /// exactly the situation a parent opened the roster to investigate.
    ///
    /// Rows belonging to no household are kept rather than hidden. `familyID` is
    /// optional and a row written before it existed has none; dropping those would
    /// silently remove a real device from the only screen that can revoke it.
    /// Ordered by label so the list does not reshuffle as devices check in.
    func enrolledDevices() -> [DeviceRecord] {
        let all = (try? context.fetch(FetchDescriptor<DeviceRecord>())) ?? []
        return all
            .filter { $0.familyID == nil || $0.familyID == householdID }
            .sorted { ($0.label, $0.id.uuidString) < ($1.label, $1.id.uuidString) }
    }

    /// Adds a device row and commits it.
    func addDevice(_ record: DeviceRecord) {
        context.insert(record)
        commitDeviceChanges()
    }

    /// Commits a change to this device's row.
    ///
    /// Awaited-and-surfaced is the rule for policy writes; a device row is not
    /// one — the worst case is a `lastSeenAt` that is a launch stale, which the
    /// next launch fixes.
    func commitDeviceChanges() {
        try? context.save()
        // A revocation is the one write here that another device has to *act* on,
        // and the device it concerns is the one that will not be asking. Same
        // fire-and-forget rule as a list edit — see ``pushLocalChanges()``.
        Task { await pushLocalChanges() }
    }

    /// The one way the binding state changes.
    ///
    /// A single seam rather than four `internal(set)` properties, because these
    /// four are one answer and a partial update is a device showing a child's
    /// player while `deviceRow` still describes the previous setup. Written by
    /// ``resolveBinding()`` in `SessionBinding.swift`, which is a different file
    /// and so cannot reach a `private(set)` setter — that restriction is doing
    /// useful work here rather than being worked around.
    func applyBinding(
        _ outcome: BindingOutcome,
        device: DeviceRecord?,
        account: AccountState,
        trouble: String? = nil
    ) {
        binding = outcome
        deviceRow = device
        signedInAccount = account
        bindingTrouble = trouble
    }

    @ObservationIgnored private let sides = HouseholdSideProvider()

    /// Sending and accepting invitations.
    ///
    /// Behind a protocol for the reason ``CatalogSource`` is: the admin screen
    /// and its copy have to be reachable with no account and no network, and
    /// the only part that genuinely needs a device is the implementation.
    @ObservationIgnored lazy var sharing: any FamilySharing = CloudKitSharing(sides: sides)

    /// The sync engine, built lazily and started once the first screen is up.
    ///
    /// Proven to work against the real container — zones created, records
    /// accepted, outbox drained.
    ///
    /// **It used to be manual, and the reason has been dealt with rather than
    /// waived.** The reason was that a co-parent could arrive holding the
    /// household zone and none of the kid zones — a half-shared household, which
    /// looks exactly like sync being slow — because the second grant step only
    /// ran when the owner happened to open the sharing screen. It now runs in
    /// ``syncPass()``, on every launch and every foreground, so the gap closes
    /// without anybody visiting a screen. That was the precondition; this is it
    /// being met.
    ///
    /// What is *not* claimed: that any of it has worked between two real
    /// accounts. See ``FamilySync/CloudKitSharing``.
    private(set) var syncEngine: SyncEngineHost?

    /// Guards the gap between deciding to build the engine and finishing, which
    /// is now `await`-wide: resolving the side talks to CloudKit, and two taps
    /// during it would otherwise build two engines over one store.
    private var startingSync = false

    /// True while an invitation is being accepted, and **nothing outbound may run
    /// while it is.**
    ///
    /// Accepting is the one operation that changes which database this device
    /// writes to. ``SyncEngineHost`` resolves that once, at `start`, so a push
    /// that began before the acceptance and lands after it hands records to an
    /// engine still addressing this device's *private* zones — where no one in the
    /// family can see them, with the outbox draining exactly as it would on
    /// success.
    ///
    /// Reachable because the pushes are deliberately detached: a parent's list
    /// edit must not wait for iCloud, so `commitDeviceChanges` and `saveLists`
    /// both spawn a push, and either can be in flight when a tapped link arrives.
    private(set) var isJoining = false

    /// Stands the outbound paths down for the length of an acceptance.
    ///
    /// A pair rather than a closure taking the work, because the work lives in
    /// `SessionSharing.swift` and needs `defer` around several awaits.
    func beginJoining() { isJoining = true }
    func endJoining() { isJoining = false }

    /// Sends whatever the store owes, once.
    ///
    /// Builds the engine on first use rather than at launch: constructing it
    /// reaches for a CloudKit container, and an app that must keep working with
    /// no iCloud account should not do that on the way to the first screen.
    func startSyncEngineIfNeeded() async {
        guard syncEngine == nil, !startingSync else { return }
        startingSync = true
        defer { startingSync = false }

        let engine = SyncEngineHost(modelContext: context, sides: sides)
        await engine.start(kids: kids.map(\.id))
        syncEngine = engine
    }

    /// Everything sync needs, in the order it needs it.
    ///
    /// **One entry point rather than three call sites remembering three steps.**
    /// The engine has to be up before anything can be handed to it, and the
    /// grants have to be reconciled before a co-parent's device has zones to
    /// receive into — a push that runs first is a push into a household that is
    /// only half shared.
    ///
    /// Run on launch, on returning to the foreground, and from the button. Each
    /// step is idempotent and doing nothing is the normal outcome, which is what
    /// makes it safe to run this often.
    /// **The order here is the whole of Stage 7's interlock.**
    ///
    /// Clears go first: they are a statement about a range, so they reach rows that
    /// have not arrived yet, and both of the steps after them move rows around.
    /// Packing next, so this device's own events are in the outbox before the push
    /// rather than waiting for the following pass. Absorbing last, because that is
    /// when a segment another device sent is on disk to find.
    ///
    /// Get it wrong in one specific way and a parent is lied to: pack before
    /// clearing and this device exports the rows it was just told to destroy.
    func syncPass() async {
        guard !isJoining else { return }
        await startSyncEngineIfNeeded()
        await reconcileOutstandingGrants()

        applyHistoryClears()
        exportActivity()

        syncEngine?.pushPendingChanges()

        absorbActivity()
        await sweepOldActivity()
    }

    /// Rolls activity past the retention window into weekly summaries and deletes it.
    ///
    /// **Last in the pass, and after absorbing.** A week summarised before another
    /// device's segments arrive is a summary of part of the week, and the rows it
    /// covers are then deleted — so it has to come after the arrivals it can still
    /// learn from. It is also the heaviest thing here, and last is where a heavy thing
    /// belongs.
    ///
    /// The floor comes from the projector rather than being assumed: sweeping through
    /// the oldest visit the live shelf references leaves a trail that cannot be
    /// rebuilt, and every kid's shelf empties the next time `RecentTrail.version`
    /// moves — months later, on an upgrade, with nothing on screen to explain it.
    private func sweepOldActivity() async {
        var swept = false
        for kid in kids {
            let floor = try? await recents.retentionFloor(for: kid.id)
            let deleted = RetentionSweep.run(for: kid.id, in: context, trailFloor: floor)
            swept = swept || deleted > 0
        }
        // The report reads on demand and `Coverage` already tells it which weeks are
        // summarised, so nothing on screen needs correcting — but the outbox now holds
        // summaries and tombstones.
        if swept { await pushLocalChanges() }
    }

    /// Packs this device's events into segments, and materialises anybody else's.
    ///
    /// **Never on the playback path** — both walk four tables, and this is the sync
    /// pass rather than the logger. A dropped log line is acceptable and a stalled
    /// player is not, and these are far heavier than a log line.
    ///
    /// Skipped entirely on a device with no row in the roster. Segments are keyed by
    /// the writing device, so a device without an identity has no key to write under
    /// — and one that invented a key each launch would re-export a child's history
    /// under a new one every time.
    private func exportActivity() {
        guard let deviceID = deviceRow?.id else { return }
        SegmentExport.pack(for: kids.map(\.id), deviceID: deviceID, in: context)
    }

    private func absorbActivity() {
        guard let deviceID = deviceRow?.id else { return }
        let inserted = SegmentExport.unpack(
            for: kids.map(\.id), deviceID: deviceID, in: context)
        // The report reads from the store on demand, so nothing needs telling — but
        // the shelf is a projection and a co-parent's device has just learned about
        // visits it had never seen.
        if inserted > 0 { Task { await loadRecentTrail() } }
    }

    /// Carries out any clear another device asked for.
    ///
    /// **Called on launch and on every sync pass rather than the moment a record
    /// lands.** Absorbing happens inside `SyncEngineHost`, which knows nothing
    /// about kids or projections, and threading this down there would put a
    /// multi-table delete on the path that receives every record. The cost is
    /// latency: a clear issued on a parent's phone reaches a child's iPad on its
    /// next foreground, not instantly. That is the right trade for this one — a
    /// deny has to be immediate because it decides what may play, and a clear does
    /// not decide anything, it destroys.
    func applyHistoryClears() {
        let touched = HistoryClearApplier.apply(
            for: kids.map(\.id), in: context, watermarks: clearWatermarks)
        guard !touched.isEmpty else { return }

        // The same screen-level tidying a local clear does, for the same reason:
        // the shelf and the queue are derived from what was just deleted, and a
        // parent told the data is gone must not find it still on the home screen.
        for kidID in touched { playQueues.clear(for: kidID) }
        if touched.contains(kid.id) {
            recentTrail = []
            discardCurrentPlay()
            historyCleared += 1
            // **Emptied first, then rebuilt from whatever survived.** Unlike a local
            // clear, an arriving instruction can be *bounded* — a clear issued last
            // Tuesday leaves this week's visits alone — so the shelf is not
            // necessarily empty afterwards. Blanking and reloading in that order
            // means the wrong answer on screen is briefly "less than there is",
            // never "something a parent was told was deleted".
            Task { await loadRecentTrail() }
        }
    }

    /// Throws the engine away so the next pass builds a new one.
    ///
    /// **The one caller is accepting an invitation, and it is not optional.**
    /// Accepting moves this device from the owner side to the joined side, and
    /// ``SyncEngineHost`` resolves the side once, in `start`. An engine built
    /// before acceptance keeps answering `.owner` and routes every write to this
    /// device's *private* database — into zones nobody else can see, with the
    /// outbox draining exactly as it would on success.
    func restartSyncEngine() async {
        syncEngine = nil
        await syncPass()
    }

    func syncNow() async {
        await syncPass()
    }

    /// Hands over what the store owes, without the rest of a pass.
    ///
    /// **What a local edit triggers.** A parent adding a deny should not wait for
    /// it to reach a child's iPad — the write is already committed and surfaced,
    /// and the transport is the part that is allowed to be slow. So this is
    /// fire-and-forget from the write path, which is the same asymmetry the log
    /// has: a delayed send is acceptable, a settings screen that blocks on iCloud
    /// is not.
    ///
    /// Deliberately *not* the whole of ``syncPass()``: the grant reconciliation in
    /// there answers "has somebody joined", which no local edit can have changed.
    func pushLocalChanges() async {
        guard !isJoining else { return }
        await startSyncEngineIfNeeded()
        // Re-checked after the await. Building the engine talks to CloudKit, so an
        // acceptance can begin and finish inside that suspension — and a push on
        // the far side of one is the wrong-database write this flag exists for.
        guard !isJoining else { return }
        syncEngine?.pushPendingChanges()
    }

    /// Bumped whenever the active kid's history is cleared.
    ///
    /// A counter rather than a callback into the player, which would be a
    /// reference from the session back up into the view layer it is read by. The
    /// kid's screen watches this and stops the player; the alternative was a
    /// parent wiping the logs and finding the bar still holding the track their
    /// child was on, which is the same loophole ``RecentTrailRecord`` is exempt
    /// from the sweep and not from a wipe to avoid.
    private(set) var historyCleared = 0

    /// How many duplicate households this launch had to fold into one.
    ///
    /// Zero on every healthy store, and it stays zero until something can
    /// create a second household — which today is nothing. It is read rather
    /// than acted on so that the repair is not *silent*: a parent who has been
    /// curating into the losing household is owed the sentence "we found two
    /// copies of your family and merged them", and an admin that says nothing
    /// leaves them to notice that their lists changed by themselves.
    ///
    /// Surfacing it is admin work that has not been done. The count is here so
    /// that it is a UI gap rather than a fact nobody kept.
    private(set) var householdsMerged = 0

    /// Bumped whenever the policy in force changes — a list edit, a suggestion,
    /// a dismissal.
    ///
    /// The same counter-rather-than-callback shape as ``historyCleared`` and for
    /// the same reason. What it exists for is narrower and was a real gap:
    /// ``rebuildEngines()`` already re-indexed the policy into everything that
    /// *judges*, but nothing re-asked about the song already coming out of the
    /// speaker. `KidPlayerModel.revalidate()` guards on `status == .stopped`,
    /// and every `queuedVerdict` call site concerns the entry queued *behind*
    /// the current one — so a parent who denied the track their child was
    /// playing watched it go on playing to the end. On one device, with no sync
    /// involved.
    ///
    /// It is also the seam a remote edit lands on later: an entry arriving from
    /// another parent's phone is the same event as one typed here, and it must
    /// not need a second mechanism.
    private(set) var policyGeneration = 0

    /// The active kid's engine, built when their policy changes and not before.
    ///
    /// **Held rather than built per call, and that is a correctness matter now
    /// rather than a saving.** `queuedVerdict` runs on every watchdog poll, and
    /// the poll tightens to 10Hz in the last five seconds of a track — some
    /// fifty builds inside the window the two-entry queue exists to protect.
    /// Building one walks `kid.entries` *and* `kid.suggestions` and every
    /// snapshot entry under them, and a to-many relationship that has not been
    /// touched yet faults in with a synchronous read on the main actor. That is
    /// exactly what ``queuedVerdict(for:)`` promises it does not do.
    ///
    /// It also stops being the odd one out: ``FilteredCatalog`` and
    /// ``MergedLibrary`` have always held a snapshot engine, and the line right
    /// after `queuedVerdict` in the player goes through one of them. Caching
    /// here removes an inconsistency rather than adding a stale surface — the
    /// invalidation set is the same one those two already have, plus dismissal.
    private var engine: PolicyEngine

    private let family: Family
    private let context: ModelContext
    private let musicAccess = MusicKitAccess()
    private let source: any CatalogSource

    /// The parent's own Apple Music library, for seeding suggestions.
    ///
    /// Deliberately not a `LibraryProvider` and deliberately not reachable from
    /// anything the kid touches: this is the seeding seam, and what it hands
    /// back is resolved to catalog items before a row is written.
    private let librarySource: any LibrarySource = MusicKitLibrarySource()

    /// Where the shared-device answer is kept. Device-local, never synced.
    private let deviceLibraryStore: any DeviceLibraryStateStore = UserDefaultsDeviceLibraryState()

    /// Which grown-up is acting on *this* device. Device-local for the reason
    /// ``deviceLibraryStore`` is — see ``ActingGrownUpStore``.
    private let actingGrownUpStore: any ActingGrownUpStore = UserDefaultsActingGrownUp()

    /// How far each kid's history has been cleared on *this* device.
    ///
    /// Device-local for the same reason: it describes what this device has already
    /// acted on, not anything about the family. See
    /// ``FamilyStore/HistoryClearWatermarkStore``.
    let clearWatermarks: any HistoryClearWatermarkStore = UserDefaultsHistoryClearWatermark()

    init(passcodes: any PasscodeStore = KeychainPasscodeStore()) throws {
        container = try FamilyStore.container()
        context = ModelContext(container)
        eventLog = EventLog(modelContainer: container)
        review = ReviewReader(modelContainer: container)
        recents = RecentsProjector(modelContainer: container)
        player = MusicKitPlayer()
        self.passcodes = passcodes

        let (family, kid, merged) = try Self.load(from: context)
        self.family = family
        self.kid = kid
        householdsMerged = merged

        let source = CachingCatalogSource(
            wrapping: MusicKitCatalogSource(),
            cache: InMemoryItemCache()
        )
        self.source = source
        let engine = kid.makeEngine()
        self.engine = engine
        catalog = FilteredCatalog(source: source, engine: engine)
        library = MergedLibrary(
            // One provider, and it is always live. The Apple Music provider is
            // the next stage; nothing above this line changes when it arrives.
            providers: [CloudKitLibraryProvider(kid: kid, context: context)],
            catalog: source,
            engine: engine,
            device: deviceLibraryStore
        )
        kids = family.orderedKids
        grownUps = family.orderedGrownUps
        deviceLibrary = deviceLibraryStore.state
        actingGrownUp = family.grownUps.first { $0.id == actingGrownUpStore.actingGrownUpID }
    }

    /// The family, and one kid to start in.
    ///
    /// **Which household, and which child, are ``FamilyResolution``'s answers**,
    /// not this one's. This is the part that is allowed to *create*.
    ///
    /// What used to be here fetched one `Family` with no predicate and no sort
    /// and then took `kids.first`, and the guard ran the two together:
    /// `if let family = …first, let kid = family.kids.first`. So a real
    /// household that happened to have no children in it yet fell through the
    /// same branch as an empty store and got a **second** household, plus a kid
    /// named `"Kid"`, as a side effect of a fetch miss. Under one device that is
    /// unreachable; the moment records arrive from a zone it is a normal
    /// hydration state, because a household and its children need not land in
    /// one step.
    ///
    /// The bootstrap that remains is deliberately the *narrow* one: a kid for a
    /// household that has none. A household is created only when there is
    /// genuinely no household — and once there is a zone to consult, "we could
    /// not reach it" must not be allowed to reach this line at all, because a
    /// device that bootstraps on an unreachable zone has forked the family with
    /// no repair path.
    private static func load(from context: ModelContext) throws -> (Family, Kid, Int) {
        if let resolved = try FamilyResolution.resolve(in: context) {
            let family = resolved.family
            // Before anything reads a roster, and before anything syncs: the
            // order a parent typed lives in the relationship's insertion order
            // and is gone the moment it does. See `captureRosterOrder`.
            let captured = FamilyResolution.captureRosterOrder(of: family)

            if let kid = FamilyResolution.activeKid(of: family) {
                // A merge and a capture are both writes, and they are the ones
                // here that must not be lost: leaving either uncommitted means
                // every launch redoes it, and the capture would then be reading
                // an order that has already been through a sync.
                if resolved.resolution.mergedAway > 0 || captured > 0 { try context.save() }
                return (family, kid, resolved.resolution.mergedAway)
            }

            let kid = Kid(name: "Kid", mode: .denyPlusAuto, unratedBehavior: .block)
            context.insert(kid)
            family.addKid(kid)
            try context.save()
            return (family, kid, resolved.resolution.mergedAway)
        }

        // Level 2 for a first kid because that is the default the product
        // recommends, and because level 1 with an empty allow list shows nothing
        // at all — a correct result that reads as a broken app.
        let family = Family()
        let kid = Kid(name: "Kid", mode: .denyPlusAuto, unratedBehavior: .block)
        context.insert(family)
        context.insert(kid)
        family.addKid(kid)
        try context.save()
        return (family, kid, 0)
    }

    // MARK: - The admin gate

    /// Whether **anything** gates this device.
    ///
    /// **Rule 8: "this family has a gate or this device has one", and it fails
    /// closed.** A device with no local item in a household that has an epoch is
    /// still gated — it will demand the household's code, which the child does not
    /// know. Reading only the local item here would let that device open a kid's
    /// player with `Enrollment` believing there was no gate over it.
    ///
    /// It fails closed in the other direction too: a kid's device whose epoch record
    /// has not arrived yet reads `false` and is refused, which is one parent typing
    /// a code rather than an ungated player.
    var isPasscodeSet: Bool { passcodes.isConfigured || householdGate() != nil }

    var isAdminOpen: Bool { gate.isOpen(at: .now) }

    /// Seconds the parent must wait before another attempt, or `nil` if none.
    var retryDelay: TimeInterval? { gate.retryDelay(at: .now) }

    /// The household's current gate, or `nil` if nobody has set one that has
    /// reached this device.
    ///
    /// Highest epoch wins. Two records can coexist briefly — two parents rotating at
    /// once produce the same number, and the merge settles it — and until it does,
    /// the newer one is the one to honour.
    func householdGate() -> HouseholdGate? {
        let rows = ((try? context.fetch(FetchDescriptor<PasscodeEpochRecord>())) ?? [])
            .filter { $0.familyID == nil || $0.familyID == householdID }
        let newest = rows.max { ($0.epoch, $0.setAt) < ($1.epoch, $1.setAt) }
        guard let latest = newest else { return nil }
        return HouseholdGate(
            epoch: latest.epoch,
            verifier: PasscodeVerifier(salt: latest.salt, verifier: latest.verifier)
        )
    }

    /// What the gate must ask for. See ``AdminGate/PasscodeEpoch``.
    var passcodeChallenge: PasscodeChallenge {
        PasscodeEpoch.challenge(
            local: passcodes.availability,
            localEpoch: (try? passcodes.record())?.epoch ?? 0,
            household: householdGate()
        )
    }

    /// Sets the household's first passcode.
    ///
    /// **Only legal when no gate exists anywhere** — otherwise this is the reset path
    /// a gate must not have, and the device that would reach for it is the child's.
    /// Rotation is ``rotatePasscode(current:to:)`` and it requires the current code.
    func setPasscode(_ passcode: String) -> String? {
        guard passcodeChallenge == .choose else { return "A passcode is already set." }
        return write(passcode, epoch: PasscodeEpoch.first, openGate: true)
    }

    /// Changes the passcode for the whole family.
    ///
    /// **The first revocation path this app has ever had.** A code that has been
    /// seen — over a shoulder, by a child watching — could not be replaced before
    /// this: `setPasscode` refused once one existed and `PasscodeStore.clear()` had
    /// no caller. Writing epoch n+1 makes every other device demand the new code,
    /// because `PasscodeEpoch.challenge` reads their local item as stale.
    func rotatePasscode(current: String, to new: String) -> String? {
        guard gate.isAcceptingAttempts(at: .now) else {
            return "Too many attempts. Try again in \(Int(retryDelay ?? 0))s."
        }
        guard verify(current) else {
            let delay = gate.failed(at: .now)
            return delay.map { "Wrong passcode. Try again in \(Int($0))s." } ?? "Wrong passcode."
        }
        gate.succeeded(at: .now)
        return write(new, epoch: PasscodeEpoch.next(after: householdGate()), openGate: false)
    }

    /// Tries a passcode. Returns nil on success, a message otherwise.
    func unlockAdmin(with passcode: String) -> String? {
        guard gate.isAcceptingAttempts(at: .now) else {
            return "Too many attempts. Try again in \(Int(retryDelay ?? 0))s."
        }
        guard verify(passcode) else {
            let delay = gate.failed(at: .now)
            // No hint about length, no note of how close it was.
            return delay.map { "Wrong passcode. Try again in \(Int($0))s." }
                ?? "Wrong passcode."
        }

        switch passcodeChallenge {
        // **Adopting on success is what closes the loop for a second device.** The
        // code was checked against the household's verifier, so this device may now
        // hold it locally — which is what gets it back onto the offline fast path
        // until somebody rotates again. Written at the epoch it was checked against,
        // never at a later one.
        case .enterHousehold(let epoch):
            _ = save(PasscodeRecord.make(passcode, epoch: epoch))

        // **Backfilling the household gate for a family that predates it.** A
        // passcode set by an older build left no epoch record, and without one a
        // second device joining that family reaches `.choose` — it would be invited
        // to set its own admin code, which is the bypass this whole mechanism
        // exists to close.
        //
        // It can only be done here, because a verifier needs the passcode itself and
        // this is the one moment the app has it. Nobody is asked anything: the
        // parent has just proved they know the code.
        case .enterLocal where householdGate() == nil:
            _ = write(passcode, epoch: PasscodeEpoch.first, openGate: false)

        case .enterLocal, .choose, .unavailable:
            break
        }

        gate.succeeded(at: .now)
        return nil
    }

    /// Checks a passcode against whichever authority the challenge names.
    ///
    /// **The household verifier is the authority whenever the local item is stale or
    /// missing**, and the local one otherwise — which is what keeps the ordinary case
    /// working with no network at all.
    private func verify(_ passcode: String) -> Bool {
        switch passcodeChallenge {
        case .enterLocal:
            return (try? passcodes.record())?.matches(passcode) ?? false
        case .enterHousehold:
            return householdGate()?.verifier.matches(passcode) ?? false
        case .choose, .unavailable:
            // Nothing to check against. Never true — an unreadable Keychain must not
            // become an open gate.
            return false
        }
    }

    /// Writes a passcode locally **and** as the household's epoch.
    ///
    /// Order matters and it is the local item first: a device that saved the epoch
    /// and then failed to save locally would demand a code from itself and be unable
    /// to check it. The reverse leaves a device holding a code the family has not
    /// heard about, which the next rotation corrects.
    private func write(_ passcode: String, epoch: Int, openGate: Bool) -> String? {
        if let failure = save(PasscodeRecord.make(passcode, epoch: epoch)) { return failure }

        let verifier = PasscodeVerifier.make(passcode)
        context.insert(
            PasscodeEpochRecord(
                familyID: householdID,
                epoch: epoch,
                salt: verifier.salt,
                verifier: verifier.verifier,
                setByGrownUpID: actingGrownUp?.id
            )
        )
        do {
            try context.save()
        } catch {
            return "Couldn't record the passcode for the family: \(error.localizedDescription)"
        }
        Task { await pushLocalChanges() }
        if openGate { gate.succeeded(at: .now) }
        return nil
    }

    private func save(_ record: PasscodeRecord) -> String? {
        do {
            try passcodes.save(record)
            return nil
        } catch {
            return "Couldn't save the passcode: \(error)"
        }
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
        kids = family.orderedKids
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
        kids = family.orderedKids
        if wasActive, let first = FamilyResolution.activeKid(of: family) {
            switchTo(first)
        }
        return failure
    }

    // MARK: - Grown-ups

    /// Adds a grown-up, and makes them the one acting if nobody was.
    ///
    /// The auto-select is the whole of the setup flow: an adult who types their
    /// name into an empty roster has said who they are, and asking them to then
    /// tap the row they just made would be the app pretending not to know.
    @discardableResult
    func addGrownUp(named name: String) -> String? {
        let grownUp = GrownUp(name: name)
        context.insert(grownUp)
        family.addGrownUp(grownUp)
        let failure = saveLists()
        grownUps = family.orderedGrownUps
        if actingGrownUp == nil { setActingGrownUp(grownUp) }
        return failure
    }

    /// Renames a grown-up, correcting the copies on everything they added.
    ///
    /// See ``FamilyStore/Family/renameGrownUp(_:to:at:)`` for why this one
    /// write-time copy is the one that gets rewritten.
    func rename(_ grownUp: GrownUp, to name: String) -> String? {
        family.renameGrownUp(grownUp, to: name)
        let failure = saveLists()
        grownUps = family.orderedGrownUps
        refreshSuggestions()
        return failure
    }

    /// Takes a grown-up off the roster.
    ///
    /// **Their shelf survives.** Every row keeps the name copied onto it at write
    /// time, so a kid does not watch "From Dad" turn back into "From your
    /// grown-up" because an adult tidied a settings screen. Unlike deleting a
    /// kid, this refuses nothing: an empty roster is a working state.
    func delete(_ grownUp: GrownUp) -> String? {
        if grownUp.id == actingGrownUp?.id { setActingGrownUp(nil) }
        family.removeGrownUp(grownUp)
        context.delete(grownUp)
        let failure = saveLists()
        grownUps = family.orderedGrownUps
        return failure
    }

    /// Says who is behind the gate on this device. Device-local, never synced.
    ///
    /// The *selection* stays local. What it implies about the Apple Account
    /// signed in here does not — see ``claimAccountForActingGrownUp()``, which is
    /// how the sharing roster comes to know a name rather than a record
    /// identifier.
    func setActingGrownUp(_ grownUp: GrownUp?) {
        actingGrownUpStore.save(grownUp?.id)
        actingGrownUp = grownUp
        claimAccountForActingGrownUp()
    }

    /// Re-reads the adult roster after something changed it.
    ///
    /// Here rather than in `SessionSharing.swift` because `grownUps` is
    /// `private(set)` and that restriction is doing useful work — a view or an
    /// extension writing the roster directly is how a display list and the store
    /// come to disagree.
    func reloadGrownUps() {
        grownUps = family.orderedGrownUps
    }

    /// Every agreement this household has on record, as the rule reads them.
    ///
    /// A fetch rather than a held copy: a co-parent's device can record one, so
    /// this changes without anything on this device doing so.
    func recordedConsent() -> [RecordedConsent] {
        let rows = (try? context.fetch(FetchDescriptor<ConsentRecord>())) ?? []
        return rows
            .filter { $0.familyID == nil || $0.familyID == householdID }
            .compactMap(\.recorded)
    }

    /// Files an agreement.
    ///
    /// **Awaited and surfaced, on the policy-write side of the rule rather than
    /// the log's.** A consent row that failed to save is the answer to "what
    /// consent did you record" being *nothing*, so it is the last thing that may
    /// be dropped quietly — see ``FamilyStore/ConsentRecord``.
    func record(_ consent: ConsentRecord) -> String? {
        context.insert(consent)
        do {
            try context.save()
        } catch {
            return error.localizedDescription
        }
        Task { await pushLocalChanges() }
        return nil
    }

    /// Records which Apple Account is which adult, and reloads the roster.
    ///
    /// A pass-through because `family` is private to this file, and it should stay
    /// that way — every write to the household goes through a named method here
    /// rather than a view reaching the model. The decision about *when* to call
    /// this is in ``claimAccountForActingGrownUp()``, which is where the reasoning
    /// belongs.
    func claimAccount(_ recordName: String?, for grownUp: GrownUp) {
        family.claimAccount(recordName, for: grownUp)
        // Through the device path rather than `saveLists`, and not by accident:
        // that one surfaces failures because a list edit is a promise to a parent.
        // This is a hint nobody asked for, so the right contract is the other one
        // — worst case it is written down on the next launch.
        commitDeviceChanges()
        reloadGrownUps()
    }

    /// What a write stamps: the identifier, and the name as it reads right now.
    ///
    /// One place rather than an argument pair repeated at each call site, because
    /// the two must never disagree about which grown-up they describe.
    private var attribution: (id: String?, name: String?) {
        (actingGrownUp?.attribution, actingGrownUp?.name)
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
        kid.addEntry(
            kind: kind,
            id: id,
            displayName: displayName,
            addedBy: attribution.id,
            addedByName: attribution.name
        )
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
        // `issuedBy` so the instruction that reaches the other devices says who
        // asked. The row it writes is what carries this off the device at all —
        // the event tables never sync, so before it existed a parent clearing the
        // logs here left the child's own iPad untouched.
        kid.deleteHistory(issuedBy: actingGrownUp?.id)
        let failure = saveLists()
        // **This device is now up to date by construction**, so the watermark moves
        // with it. Without this the applier would find its own instruction
        // outstanding on the next pass and do the whole sweep again — harmless, and
        // a full scan of four event tables for nothing.
        clearWatermarks.setWatermark(.now, for: kid.id)
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
        kid.deleteEverything(issuedBy: actingGrownUp?.id)
        let failure = saveLists()
        // Same reason as ``deleteHistory(for:)``: this device has already done the
        // work, so it should not find its own instruction outstanding next launch.
        clearWatermarks.setWatermark(.now, for: kid.id)
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

        guard let subscription = try? await musicAccess.subscriptionState() else { return }
        hasCloudLibrary = subscription.hasCloudLibraryEnabled
        guard !subscription.canPlayCatalogContent else { return }
        access = .cannotPlay(subscription)
    }

    /// Whether Sync Library is on for the signed-in account.
    ///
    /// `nil` until the subscription check answers, and left `nil` when it cannot
    /// be reached — the same rule the check itself follows, that a failure to
    /// reach Apple is not a negative answer. The parent's library picker is
    /// hidden only on a definite `false`, so an offline admin session shows the
    /// tab and lets the read fail with its own error rather than telling a
    /// parent their library is off when nobody asked.
    private(set) var hasCloudLibrary: Bool?

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
        switch engine.evaluate(item.policyItem) {
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

    /// Who added each thing on the allow list.
    ///
    /// Built from the records rather than carried on the resolved items, because
    /// resolution goes through the catalog and the catalog knows nothing about
    /// this family. First row wins where the same item was allowed twice — the
    /// list is allowed to hold duplicates and a tile can only sit on one shelf.
    private var allowListAttribution: [CatalogID: (id: String?, name: String?)] {
        var out: [CatalogID: (id: String?, name: String?)] = [:]
        for record in kid.entries {
            guard let entry = record.entry, entry.kind == .allow else { continue }
            if out[entry.id] == nil {
                out[entry.id] = (record.addedBy, record.addedByName)
            }
        }
        return out
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
        kid.effectiveMode == .allowOnly ? try await allowListItems() : []
    }

    /// What each grown-up picked out, one shelf per adult.
    ///
    /// **Within** a shelf: what that grown-up suggested, then what they allowed
    /// and have not suggested. One heading over both halves, because the kid's
    /// question is *what did they pick for me* and two headings answering it
    /// differently is the app showing its own bookkeeping. Suggestions lead
    /// because they are the deliberate act and the dismissible half; the
    /// allow-list tail is still level 1 only, for the reason ``grownUpItems()``
    /// records.
    ///
    /// **Across** shelves: split by who, because two parents curate separately.
    /// Everything nobody is named on collects in one trailing shelf reading "From
    /// your grown-up", which is the whole of the home screen for a household that
    /// never fills the roster.
    ///
    /// Anything suggested is dropped from the tail rather than drawn twice —
    /// suggesting something *is* allowing it, so at level 1 every suggestion
    /// would otherwise appear once as itself and once as its own allow. Deduped
    /// across *all* shelves rather than within one, because a suggestion moving
    /// to Mum's shelf must not leave Dad's allow of the same album drawing it
    /// again underneath.
    func grownUpShelves() async throws -> [GrownUpShelf] {
        async let suggested = attributedSuggestionTiles()
        async let allowed = grownUpItems()

        let tiles = try await suggested
        let seen = Set(tiles.compactMap(\.tile.catalogID))

        // Guarded rather than computed unconditionally: the tail is level 1 only,
        // and `allowListAttribution` walks `kid.entries` — a to-many that faults
        // in with a synchronous read. Levels 2 and 3 answer empty here and should
        // not pay for a walk whose result they discard.
        var tail: [AttributedTile] = []
        let allowedItems = try await allowed
        if !allowedItems.isEmpty {
            let attribution = allowListAttribution
            tail = allowedItems.filter { !seen.contains($0.id) }.map { item in
                let who = attribution[item.id] ?? (nil, nil)
                return AttributedTile(tile: .item(item), addedBy: who.id, addedByName: who.name)
            }
        }

        return Self.shelves(
            from: tiles + tail,
            roster: grownUps.map { ($0.attribution, $0.name) }
        )
    }

    /// Groups tiles into shelves. Pure, and the only place the ordering rule
    /// lives.
    ///
    /// Roster order first, because that is the order an adult typed the names in
    /// and the only order in the app that a person chose. Grown-ups no longer on
    /// the roster follow, in the order their tiles appear — they still have rows
    /// and those rows still have a name copied onto them. The unnamed shelf is
    /// always last: it is the residue, and putting it above somebody's actual
    /// name would read as the more important of the two.
    ///
    /// The **live** roster name wins over the copy where there is one, so a
    /// rename shows up even if the backfill across rows did not land. The copy is
    /// what carries a removed grown-up.
    ///
    /// **An attribution nobody can be named for is treated as unattributed**, and
    /// folded into the residue rather than given a shelf of its own. Nothing
    /// writes that state today — the identifier and the name are stamped together
    /// or not at all — but the alternative if it ever arrives is two shelves both
    /// headed "From your grown-up", which reads as a bug to a child and is one.
    static func shelves(
        from tiles: [AttributedTile],
        roster: [(attribution: String, name: String)]
    ) -> [GrownUpShelf] {
        let liveNames = Dictionary(
            roster.map { ($0.attribution, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        var order: [String] = roster.map(\.attribution)
        var grouped: [String: [SuggestedTile]] = [:]
        var names: [String: String] = [:]

        for tile in tiles {
            let name = tile.addedBy.flatMap { liveNames[$0] } ?? tile.addedByName
            let key =
                if let attribution = tile.addedBy, name != nil {
                    attribution
                } else {
                    GrownUpShelf.unattributed
                }
            if grouped[key] == nil, !order.contains(key) { order.append(key) }
            grouped[key, default: []].append(tile.tile)
            if key != GrownUpShelf.unattributed, names[key] == nil { names[key] = name }
        }

        // The residue goes last however it got into `order`. It is appended in
        // tile order above, which is wherever the first unnamed row happened to
        // fall, and that is not where it belongs.
        let keys =
            order.filter { $0 != GrownUpShelf.unattributed }
            + (grouped[GrownUpShelf.unattributed] != nil ? [GrownUpShelf.unattributed] : [])

        return keys.compactMap { key in
            // A grown-up with nothing currently reachable contributes no shelf
            // rather than an empty band under their name.
            guard let tiles = grouped[key], !tiles.isEmpty else { return nil }
            return GrownUpShelf(id: key, name: names[key], tiles: tiles)
        }
    }

    /// The suggestions, resolved and judged.
    ///
    /// **Filtered at render time**, like every other shelf: a parent can deny
    /// today what they suggested last week, and a deny outranks a suggestion in
    /// every mode. Blocks are *not* logged here — these are stored rows, so
    /// logging them would write the same block once per appearance of the home
    /// screen. Same rule as favorites.
    ///
    /// A snapshot playlist has no catalog identifier, so there is no
    /// `CatalogItem` to hand the engine and the tile would go unjudged. It is
    /// judged through its contents instead: the tile survives while at least one
    /// track does. Otherwise a parent denying the artist leaves a kid a tile that
    /// opens onto nothing.
    ///
    /// Those tracks are judged from the stored row alone, with no rating in it,
    /// and that is sound rather than lucky — a live suggestion puts an allow on
    /// each track *itself*, and an allow on the item is the one thing that
    /// overrides the rating check at level 2. What the stored lineage is for is
    /// the other direction: it is what lets a deny on the artist still reach
    /// them here, offline.
    func suggestionTiles() async throws -> [SuggestedTile] {
        try await attributedSuggestionTiles().map(\.tile)
    }

    /// The same tiles, each still knowing which grown-up put it there.
    ///
    /// Separate from ``suggestionTiles()`` rather than folded into it because the
    /// attribution is only ever wanted by the grouping in
    /// ``grownUpShelves()`` — every other caller wants tiles and would be
    /// unpicking a pair for nothing.
    func attributedSuggestionTiles() async throws -> [AttributedTile] {
        let rows = suggestions
        guard !rows.isEmpty else { return [] }

        let ids = rows.compactMap(\.catalogID)
        var resolved: [CatalogID: CatalogItem] = [:]
        if !ids.isEmpty {
            let items = try await source.items(for: ids)
            let withAncestry = try await source.resolveAncestry(for: items)
            resolved = Dictionary(
                withAncestry.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        return rows.compactMap { row in
            let tile: SuggestedTile?
            if let catalogID = row.catalogID {
                // A catalog answer that never came leaves the tile out rather
                // than drawing an identifier. Unlike the Recent shelf there is
                // nothing here a kid recognises from having been there.
                if let item = resolved[catalogID], engine.evaluate(item.policyItem).isAllowed {
                    tile = .item(item)
                } else {
                    tile = nil
                }
            } else {
                tile = row.hasReachableSong(under: engine) ? .snapshotPlaylist(row) : nil
            }
            guard let tile else { return nil }
            return AttributedTile(tile: tile, addedBy: row.addedBy, addedByName: row.addedByName)
        }
    }

    /// The songs inside a suggested playlist, judged locally and in order.
    ///
    /// No catalog round trip: the rows were resolved when the parent suggested
    /// it and carry their own lineage. See ``suggestionTiles()`` for why that is
    /// enough to judge them.
    func suggestedPlaylistSongs(_ local: UUID) -> [CatalogItem] {
        guard let row = suggestions.first(where: { $0.id == local }) else { return [] }
        return row.reachableSongs(under: engine)
    }

    func suggestedPlaylist(_ local: UUID) -> SuggestionRow? {
        suggestions.first { $0.id == local }
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
                // Started here and **not awaited**: keeping an artist means
                // keeping their work, and finding all of it is fifty round trips.
                // The heart is already safe by this line; the rest fills in while
                // the kid carries on using the app.
                expand(item)
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
            return Self.kidMessage(for: error)
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
        refreshSuggestions()
    }

    /// Re-reads the suggestion rows. Synchronous — they are ours and local.
    func refreshSuggestions() {
        suggestions = kid.liveSuggestions
        dismissedSuggestions = kid.dismissedSuggestions
    }

    /// Indexes everything under something the kid just kept, in the background.
    ///
    /// **Nothing waits on this and nothing reports it.** The kid asked for the
    /// artist and got the artist; what is underneath arriving over the next
    /// several seconds is the app catching up, not an operation with an outcome
    /// they need to be told about. A failure leaves the index short and the next
    /// heart of the same thing walks again.
    ///
    /// Held so a kid switch can cancel it — one child's walk must not go on
    /// writing into a library after a parent has handed the device to another,
    /// and `Kid` is captured by the provider the walk writes through.
    private func expand(_ item: CatalogItem) {
        guard item.id.kind == .album || item.id.kind == .artist else { return }
        walks[item.id]?.cancel()
        walks[item.id] = Task { [weak self] in
            guard let self else { return }
            await library.expand(item)
            guard !Task.isCancelled else { return }
            walks[item.id] = nil
            // Only now, and only once. The rows landed as the walk found them,
            // but re-reading the whole library after each of fifty steps would
            // cost more than the walk does.
            if hasLoadedLibrary { await loadLibrary() }
        }
    }

    /// Walks in flight, by what they are walking.
    private var walks: [CatalogID: Task<Void, Never>] = [:]

    /// Stops every walk. What a kid switch and a wipe both need.
    private func cancelWalks() {
        for walk in walks.values { walk.cancel() }
        walks.removeAll()
    }

    /// The "Library" shelf: the kid's most recent favorites, newest first.
    ///
    /// **The blocked half is deliberately not logged here**, which is the one
    /// place in the app that is true. Everywhere else a block is a transient
    /// result of something a kid just did — a search, a browse — and logging it
    /// is the only way it survives to reach a parent. A blocked favorite is a
    /// stored row that is still there, so the report can find it whenever it is
    /// asked. Logging on every redraw would write the same block once per home
    /// screen appearance and drown the report in it.
    ///
    /// **Capped, like Recent beside it.** ``TileShelf`` is a plain `HStack` and
    /// not a lazy one, so every tile it is handed is built whether or not it is
    /// ever scrolled to — a kid with four hundred favorites was building four
    /// hundred tiles and four hundred artwork loads on every draw of the home
    /// screen. A shelf is what fits on a line and a bit; the chevron beside it
    /// opens the browser, which is where all of them live.
    ///
    /// The limit is applied **after** filtering, for the reason
    /// ``homeItems(limit:)`` records: taking it first lets a denied favorite eat
    /// one of the slots and the shelf comes back short.
    func favoriteItems(limit: Int = 24) async throws -> [CatalogItem] {
        Array(try await library.favorites().items.prefix(limit))
    }

    /// One playlist's songs, in the order the kid put them in. Blocks are not
    /// logged, for the same reason.
    ///
    /// **The whole result rather than its items**, because an empty `items` is
    /// two different screens and only one of them is about the child: a playlist
    /// with nothing in it, and one whose songs could not be read. `isResolved` is
    /// the only thing that tells them apart, and dropping it here is what let a
    /// failed catalog read render as *"Nothing in here yet"* over three hundred
    /// songs a kid had put there themselves.
    func playlistSongs(_ handle: PlaylistHandle) async throws -> LibraryResults {
        try await library.songs(in: handle)
    }

    /// A local predicate over the kid's own rows. Never a catalog search, and
    /// never `MusicLibrarySearchRequest`.
    func searchLibrary(_ term: String) async throws -> [CatalogItem] {
        try await library.searchLibrary(term).items
    }

    /// The whole library, resolved and judged, for the browser to filter.
    ///
    /// **Held here rather than in the view** for the same reason `favoriteIDs`
    /// and `playlists` are: the browser's columns are pushed screens, rebuilt
    /// from a route every time the stack changes, and a column that fetched on
    /// appearance would put a spinner between a tap and the albums it opened.
    /// One read fills every column and every drill-in below it.
    ///
    /// Blocks are not logged, for the reason on ``favoriteItems()``.
    private(set) var libraryContents = LibraryContents.empty

    /// Whether ``libraryContents`` has ever been filled. What tells an empty
    /// library apart from one that has not been read yet — the difference
    /// between "nothing kept" and a blank screen.
    private(set) var hasLoadedLibrary = false

    /// Reads the library for the browser. Safe to call again; it replaces.
    func loadLibrary() async {
        libraryContents = await library.contents()
        hasLoadedLibrary = true
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
            return Self.kidMessage(for: error)
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
            return Self.kidMessage(for: error)
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
            artworkURL: artworkURL,
            addedBy: attribution.id,
            addedByName: attribution.name
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

    // MARK: - Suggestions
    //
    // Awaited and surfaced like the lists above, and every one of them goes
    // through `rebuildEngines()`. **Dismissal is the first kid-side action in
    // this app that changes what the kid may reach**, and it changes it in the
    // narrowing direction — the one that must never lag behind the tap.

    /// Puts something in front of the kid, and makes it reachable.
    ///
    /// Takes a resolved item rather than an identifier so the name and artwork
    /// are copied from what the parent was actually looking at.
    ///
    /// **A playlist is snapshotted even when it is Apple's own.** An allow on a
    /// playlist identifier reaches the playlist and nothing inside it — nothing
    /// in this app puts a playlist into a track's lineage, and `resolveAncestry`
    /// skips them on purpose — so a suggested playlist without its tracks
    /// resolved would open, at level 1, onto forty blocked rows. Refusing when
    /// the track list cannot be read is the honest answer: the alternative is a
    /// tile that looks suggested and plays nothing.
    func suggest(_ item: CatalogItem, note: String? = nil) async -> String? {
        var songs: [CatalogItem] = []
        if item.id.kind == .playlist {
            guard let tracks = try? await source.children(of: item.id), !tracks.isEmpty else {
                return "Couldn't read that playlist's songs. Try again in a moment."
            }
            songs = (try? await source.resolveAncestry(for: tracks)) ?? tracks
        }
        return suggest(
            target: .catalog(item.id),
            displayName: item.title,
            subtitle: item.subtitle,
            artworkURL: item.artworkURL,
            note: note,
            songs: songs
        )
    }

    // MARK: - Suggesting out of the parent's own library
    //
    // **The parent's library, never the kid's.** This is `LibrarySource` — the
    // seeding seam — and no part of it goes through `KidLibrary`. The rule it
    // keeps is the one that makes every other rule work: a library pick becomes
    // a *catalog* item before anything is stored, so there is one namespace and
    // a deny on an artist reaches everything of theirs.

    /// The account's own playlists, Apple's and the parent's alike.
    func libraryPlaylists(limit: Int = 100) async throws -> [LibraryPlaylist] {
        try await librarySource.libraryPlaylists(limit: limit)
    }

    /// The account's own albums, songs or artists.
    func libraryItems(kinds: Set<ItemKind>, limit: Int = 100) async throws -> [LibraryItem] {
        if kinds == [.artist] {
            return try await librarySource.libraryArtists(limit: limit)
        }
        return try await librarySource.libraryItems(kinds: kinds, limit: limit)
    }

    /// Matches a library album or song to the catalog.
    func resolveFromLibrary(_ items: [LibraryItem]) async throws -> LibraryImport {
        try await librarySource.resolveToCatalog(items)
    }

    /// Names a library artist in the catalog. See ``ArtistVote``.
    func resolveLibraryArtist(_ artist: LibraryItem) async throws -> ArtistResolution {
        try await librarySource.resolveArtist(artist)
    }

    /// Resolves a library playlist's tracks, ready to be snapshotted.
    ///
    /// Returns the discards as well as the matches, because the parent is shown
    /// both before they commit — "34 of 39 matched, 5 aren't on Apple Music" is
    /// the only honest thing to put in front of someone about to hand their kid
    /// a playlist, and a silent 34 reads as the whole thing.
    func resolveLibraryPlaylist(_ playlist: LibraryPlaylist) async throws -> LibraryImport {
        let tracks = try await librarySource.tracks(of: playlist)
        guard !tracks.isEmpty else { return .empty }
        return try await librarySource.resolveToCatalog(tracks)
    }

    /// Commits one row of the parent's draft.
    ///
    /// A snapshot gets a fresh local identifier every time, so suggesting the
    /// same library playlist twice makes two rows rather than upserting onto
    /// one. That is the honest reading of the act: the parent's playlist has
    /// moved on since, this is a new photograph of it, and the first one is
    /// still what the kid was given.
    func suggest(_ draft: SuggestionDraftItem, note: String?) async -> String? {
        switch draft {
        case .catalog(let item):
            return await suggest(item, note: note)
        case .snapshot(let name, let songs, _):
            return suggest(
                target: .snapshotPlaylist(local: UUID()),
                displayName: name,
                note: note,
                songs: songs
            )
        }
    }

    /// What suggesting this would actually get the kid.
    ///
    /// `nil` where the question does not apply — an artist has no bounded track
    /// list to count, and a song is one thing.
    ///
    /// It exists because of an inversion suggestions make visible for the first
    /// time. At level 2 an allow on a *container* does not lift the rating check
    /// off its children, so a suggested album's explicit tracks stay blocked; at
    /// level 1 an allow-listed ancestor is enough and no rating is consulted, so
    /// the same tracks play. A parent who suggests a fourteen-track album and
    /// hears twelve has been told; one who has not will file it as a bug.
    func suggestionPreview(for item: CatalogItem) async -> SuggestionPreview? {
        guard item.id.kind == .album || item.id.kind == .playlist else { return nil }
        guard let children = try? await source.children(of: item.id) else { return nil }
        let tracks = (try? await source.resolveAncestry(for: children)) ?? children
        guard !tracks.isEmpty else { return nil }

        // The policy as it *would* be, not as it is — the point is to answer a
        // question about a suggestion that has not been made yet.
        var entries = kid.buildPolicy().policy.entries
        entries.append(.allow(item.id))
        if item.id.kind == .playlist {
            entries.append(contentsOf: tracks.map { PolicyEntry.allow($0.id) })
        }
        let hypothetical = PolicyEngine(
            policy: Policy(
                mode: kid.effectiveMode,
                entries: entries,
                unratedBehavior: kid.effectiveUnratedBehavior
            )
        )
        let playable = tracks.filter { hypothetical.evaluate($0.policyItem).isAllowed }.count
        return SuggestionPreview(playable: playable, total: tracks.count)
    }

    func suggest(
        target: SuggestionTarget,
        displayName: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        note: String? = nil,
        songs: [CatalogItem] = []
    ) -> String? {
        let record = kid.addSuggestion(
            target: target,
            displayName: displayName,
            subtitle: subtitle,
            artworkURL: artworkURL,
            note: note,
            addedBy: attribution.id,
            addedByName: attribution.name
        )
        for song in songs where song.id.kind == .song {
            record.addSong(
                id: song.id,
                displayName: song.title,
                artworkURL: song.artworkURL,
                ancestry: song.libraryAncestry
            )
        }
        return saveSuggestions()
    }

    /// The parent took it back. The reach goes with it.
    func withdrawSuggestion(_ row: SuggestionRow) -> String? {
        guard let record = record(for: row) else { return nil }
        kid.removeSuggestion(record)
        return saveSuggestions()
    }

    /// The kid passed on it. The row stays so the parent can see it did.
    func dismissSuggestion(_ row: SuggestionRow) -> String? {
        guard let record = record(for: row) else { return nil }
        kid.dismissSuggestion(record)
        return saveSuggestions()
    }

    /// The parent offered it again, back at the front of the shelf.
    func restoreSuggestion(_ row: SuggestionRow) -> String? {
        guard let record = record(for: row) else { return nil }
        kid.restoreSuggestion(record)
        return saveSuggestions()
    }

    private func record(for row: SuggestionRow) -> SuggestionRecord? {
        kid.suggestions.first { $0.id == row.id }
    }

    /// Saves, then re-indexes the policy — but does **not** blank the library
    /// browser the way a list edit does.
    ///
    /// A parent's list edit can invalidate any screen, so it drops the browser's
    /// copy wholesale. A suggestion cannot: it only ever adds reach, or removes
    /// reach to something that was never in the kid's library to begin with. So
    /// the engines are rebuilt and the shelves re-read, and the screen the kid is
    /// looking at stays where it is.
    private func saveSuggestions() -> String? {
        do {
            try context.save()
        } catch {
            return error.localizedDescription
        }
        rebuildEngines()
        refreshSuggestions()
        return nil
    }

    private func saveLists() -> String? {
        do {
            try context.save()
        } catch {
            return error.localizedDescription
        }
        rebuildCatalog()
        // Detached on purpose — see ``pushLocalChanges()``. The edit is already
        // saved and this screen is already correct; what happens next is
        // transport, and a parent must never watch a spinner for it.
        Task { await pushLocalChanges() }
        return nil
    }

    /// Rebuilds everything that holds a policy engine, and re-reads what it
    /// judged. What a parent's edit turns into.
    private func rebuildCatalog() {
        rebuildEngines()
        reloadLibraryContents()
    }

    /// Re-indexes the policy into the three things that hold one.
    ///
    /// All three, always. A policy edit that reached the catalog but not the
    /// library would leave a denied artist off search results and still on the
    /// kid's shelf — the one screen a parent is least likely to check.
    ///
    /// Split out from ``rebuildCatalog()`` because this half is cheap and the
    /// other half is not, and one caller needs only this: a kid dismissing a
    /// suggestion changes what they may reach and must take effect at once, but
    /// blanking the library browser under them because they tapped "no thanks"
    /// on the home screen would be the app flinching at its own bookkeeping.
    private func rebuildEngines() {
        // Whatever is being walked belongs to the kid and the policy that were
        // current when it started. A walk writes through a provider holding a
        // `Kid`, so one left running past a kid switch would keep filing one
        // child's artist into whichever library is open now.
        cancelWalks()
        let engine = kid.makeEngine()
        self.engine = engine
        policyGeneration += 1
        catalog = FilteredCatalog(source: source, engine: engine)
        library = MergedLibrary(
            providers: [CloudKitLibraryProvider(kid: kid, context: context)],
            catalog: source,
            engine: engine,
            device: deviceLibraryStore
        )
    }

    /// Drops what the previous engine judged and reads it again.
    private func reloadLibraryContents() {
        // The heart and the shelves read from a different kid's rows now, or from
        // the same kid's under a new policy. Neither is what is on screen.
        //
        // The browser's copy goes with them, and has to be dropped rather than
        // left to refresh: it was judged by the engine that just stopped being
        // the policy, and every column and drill-in below it is a filter of that
        // one value. A parent denying an artist with the library open would
        // otherwise leave them sitting there, on the one screen a kid is most
        // likely to be looking at.
        let wasBrowsing = hasLoadedLibrary
        libraryContents = .empty
        hasLoadedLibrary = false
        Task {
            await refreshLibrary()
            // Only for a screen that already had it. Reading it for a kid who
            // has never opened the library would spend a request on a screen
            // nobody is looking at.
            if wasBrowsing { await loadLibrary() }
        }
    }

    /// What a **grown-up** is told went wrong.
    ///
    /// Diagnostic on purpose: a parent can act on the difference between a
    /// missing subscription and Screen Time, and the whole point of
    /// ``CatalogError`` is that a named case is a sentence we can write rather
    /// than a support ticket. The `localizedDescription` fallback is right here
    /// — an adult reading a framework's own words is better served than an adult
    /// reading "something went wrong".
    ///
    /// **Never call this from a kid surface.** See ``kidMessage(for:)``.
    static func message(for error: any Error) -> String {
        (error as? CatalogError)?.errorDescription ?? error.localizedDescription
    }

    /// What a **child** is told went wrong.
    ///
    /// **No string a framework wrote ever reaches this screen.** That rule was
    /// stated in ``NowPlayingBar`` and ``NowPlayingView`` from the beginning —
    /// "plain words, no error code, and no mention of the rule" — and was not
    /// true: this used to be ``message(for:)``, whose fallback is
    /// `localizedDescription`, and a kid was shown *"The operation couldn't be
    /// completed. (MPMusicPlayerControllerErrorDomain error 6.)"* on the
    /// full-screen player. Found by running the app, not by reading it.
    ///
    /// ``CatalogError``'s own descriptions are no better here, which is the part
    /// that makes this a separate function rather than a better fallback: they
    /// are written for the person who can fix the problem. "Check Screen Time's
    /// music restriction and Apple Music's parental controls" is a correct
    /// sentence addressed to nobody in this room.
    ///
    /// So the mapping is deliberately lossy, and collapses to **what the child
    /// can do about it**. Four outcomes, because a six-year-old has four moves:
    /// wait, pick something else, fetch an adult, or try again. The distinction
    /// between no subscription, revoked permission, Sync Library and an outside
    /// restriction is real and is invisible from here — all four are "fetch an
    /// adult", and spending four sentences on it would only be the app showing a
    /// child its own bookkeeping.
    ///
    /// The detail is not lost: every grown-up surface still calls
    /// ``message(for:)`` with the same error.
    /// What a kid is told when a screen came back empty because the catalog did
    /// not answer.
    ///
    /// Reached without an error to map: ``KidLibrary/LibraryResults/isResolved``
    /// is a flag rather than a thrown thing, and the failure it reports was
    /// already swallowed a layer down so the shelves could still draw. It routes
    /// through ``kidMessage(for:)`` anyway rather than carrying a sentence of its
    /// own, so this cannot drift out of the four things a child is ever shown.
    static var kidUnresolvedMessage: String {
        kidMessage(for: CatalogError.underlying("the catalog did not answer"))
    }

    static func kidMessage(for error: any Error) -> String {
        switch error as? CatalogError {
        case .offline:
            "No internet right now. Let's try again in a bit."
        case .itemUnavailable:
            "This one isn't here anymore."
        case .notAuthorized, .noSubscription, .cloudLibraryDisabled, .restrictedOutsideApp:
            "Ask a grown-up to help with this one."
        // `.underlying` carries a framework's words, so it belongs here with the
        // errors that are not `CatalogError` at all rather than with the named
        // cases above.
        case .underlying, .none:
            "That didn't work. Let's try again."
        }
    }
}
