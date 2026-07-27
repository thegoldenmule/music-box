import CatalogKit
import FamilyStore
import Foundation
import SwiftData

/// Everything one run of the app needs, wired together once.
///
/// This is the thin slice's stand-in for what will become the parent admin
/// picking a kid and the player screen taking over. There is no passcode, no kid
/// list and no real UI here — the point is to prove the seams meet: MusicKit
/// authorizes, the catalog filters through the policy engine, playback starts,
/// and the log records it.
@MainActor
@Observable
final class Session {
    /// What the app is allowed to do right now, before any of it is worth
    /// showing.
    enum Gate {
        case checking
        case needsAuthorization(AuthorizationStatus)
        case cannotPlay(SubscriptionState)
        case ready
        case failed(String)
    }

    private(set) var gate: Gate = .checking

    let container: ModelContainer
    let eventLog: EventLog
    let player: MusicKitPlayer
    let kid: Kid

    /// Rebuilt whenever the kid's policy changes — the engine indexes the lists
    /// once, so it is per-policy rather than per-search.
    private(set) var catalog: FilteredCatalog

    private let context: ModelContext
    private let access = MusicKitAccess()
    private let source: any CatalogSource

    init() throws {
        container = try FamilyStore.container()
        context = ModelContext(container)
        eventLog = EventLog(modelContainer: container)
        player = MusicKitPlayer()

        kid = try Self.demoKid(in: context)

        source = CachingCatalogSource(
            wrapping: MusicKitCatalogSource(),
            cache: InMemoryItemCache()
        )
        catalog = FilteredCatalog(source: source, engine: kid.makeEngine())
    }

    /// One kid, created on first launch and reused after.
    ///
    /// Level 2 because that is the default the product recommends, and because
    /// level 1 with an empty allow list would show nothing at all — a correct
    /// result that makes a smoke test look broken.
    private static func demoKid(in context: ModelContext) throws -> Kid {
        var descriptor = FetchDescriptor<Kid>()
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let family = Family()
        let kid = Kid(name: "Demo", mode: .denyPlusAuto, unratedBehavior: .block)
        context.insert(family)
        context.insert(kid)
        family.addKid(kid)
        try context.save()
        return kid
    }

    // MARK: - Gate

    func start() async {
        let status = await access.requestAuthorization()
        guard status == .authorized else {
            gate = .needsAuthorization(status)
            return
        }

        do {
            let subscription = try await access.subscriptionState()
            gate = subscription.canPlayCatalogContent ? .ready : .cannotPlay(subscription)
        } catch {
            gate = .failed(Self.message(for: error))
        }
    }

    // MARK: - Searching

    /// Searches, and logs what came back — including everything filtered out.
    ///
    /// Blocked results are logged even though the kid never saw them. They are
    /// the most useful line in a parent's report: they are how a parent finds
    /// out what their kid is curious about.
    func search(term: String, limit: Int = 25) async throws -> FilteredResults {
        let results = try await catalog.search(term: term, kinds: [.song], limit: limit)

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

        return results
    }

    // MARK: - Playing

    /// Refused at the moment of playback, carrying why.
    struct Refused: Error {
        let reason: BlockReason
    }

    private var playingOrigin: PlaybackOrigin?

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
    private func logCurrentPlay() {
        guard let item = player.nowPlaying, let origin = playingOrigin else { return }

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
        kid.addEntry(
            kind: .deny,
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

    private func rebuildCatalog() {
        catalog = FilteredCatalog(source: source, engine: kid.makeEngine())
    }

    static func message(for error: any Error) -> String {
        (error as? CatalogError)?.errorDescription ?? error.localizedDescription
    }
}
