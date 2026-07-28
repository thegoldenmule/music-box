#if canImport(MusicKit)

import Foundation
import MusicKit
import PolicyEngine

/// ``CatalogPlayer`` on top of `ApplicationMusicPlayer`.
///
/// Application queue rather than system queue on purpose: the system player
/// shares state with the Music app, so what a kid plays here would reorder the
/// parent's own Up Next, and what the parent queued in Music would arrive here
/// unvetted.
///
/// **Availability.** `ApplicationMusicPlayer` is the reason the macOS floor is
/// 14.0. There is no in-app playback below it.
@MainActor
public final class MusicKitPlayer: CatalogPlayer {
    private let player = ApplicationMusicPlayer.shared

    public private(set) var nowPlaying: CatalogItem?

    public init() {}

    public var status: PlaybackStatus {
        switch player.state.playbackStatus {
        case .playing: .playing
        case .paused: .paused
        case .interrupted: .interrupted
        case .stopped: .stopped
        // seekingForward and seekingBackward are transient and only reachable
        // through controls this app does not offer.
        default: .playing
        }
    }

    public var playbackTime: TimeInterval {
        max(0, player.playbackTime)
    }

    /// The player's own word for what it is doing, unmapped.
    ///
    /// ``status`` folds everything it does not recognise into `playing`, which
    /// is the right call for a button — a control that flickers is worse than
    /// one that is briefly optimistic — and exactly the wrong one for working
    /// out why a track did not advance. Two of the five states this can report
    /// have no case in ``PlaybackStatus`` at all.
    ///
    /// **Diagnostic only.** Nothing decides anything on this string; it exists
    /// so the end-of-queue behaviour can be *read* rather than guessed at, which
    /// it still is — see `KidPlayerModel.hasEnded`.
    public var rawStatus: String {
        String(describing: player.state.playbackStatus)
    }

    /// The player's own identifier for the queue entry it is sitting on.
    ///
    /// **The question `playbackStatus` cannot answer.** A status says what the
    /// player is doing; this says *what it is doing it to*. The two come apart
    /// in the case this app cares about most: the queue here holds exactly one
    /// song, so anything that moves the player off that song — the track
    /// finishing, or the next-track button on the lock screen, which reaches
    /// `ApplicationMusicPlayer` directly and never passes through the app — has
    /// run the queue out. Whether the resulting state reports as stopped, paused
    /// or something with no case in ``PlaybackStatus`` at all is a detail; that
    /// the entry we asked for is no longer loaded is not.
    ///
    /// `nil` once the queue is exhausted, and before anything has been queued.
    public var currentEntryID: String? {
        player.queue.currentEntry?.id
    }

    /// Heard before the current stretch began. Everything since is `playbackTime
    /// - stretchStart`, so nothing has to be sampled on a timer: a seek is the
    /// only event that breaks the correspondence between position and listening,
    /// and a seek is something this type is told about.
    private var heardBeforeStretch: TimeInterval = 0
    private var stretchStart: TimeInterval = 0

    public var playbackSeconds: Int {
        max(0, Int(heardBeforeStretch + max(0, playbackTime - stretchStart)))
    }

    public func seek(to seconds: TimeInterval) async {
        // Bank the stretch that ends here before moving, or a kid who drags back
        // to the start erases the minute they just listened to.
        heardBeforeStretch += max(0, playbackTime - stretchStart)
        let target = max(0, seconds)
        stretchStart = target
        player.playbackTime = target
    }

    /// The song most recently fetched ahead of time, and which item it is for.
    ///
    /// Exactly one, and it is a cache rather than a queue: nothing plays from
    /// here without ``play(_:)`` being asked for that item by name. A stale one
    /// — the kid tapped something else — is simply never matched and is replaced
    /// by the next preload.
    private var preloaded: (id: CatalogID, song: Song)?

    public func preload(_ item: CatalogItem) async {
        guard item.id.kind == .song, preloaded?.id != item.id else { return }
        // Failure is silence, not an error: the worst case is the gap this was
        // trying to close, and the real fetch in `play(_:)` will report anything
        // that is actually wrong at the moment it matters.
        guard let song = try? await Self.fetch(item) else { return }
        preloaded = (item.id, song)
    }

    public func play(_ item: CatalogItem) async throws {
        guard item.id.kind == .song else {
            // The slice plays songs. Albums and playlists become queues, which
            // is a policy question (every track judged, blocked ones skipped
            // rather than stopped on) and not a mechanical one.
            throw CatalogError.underlying(
                "Only songs can be played directly; \(item.id.kind.rawValue) needs a queue."
            )
        }

        // The preloaded song when it is the one being asked for, which is the
        // whole saving: a track that follows another in a queue has had its
        // round trip made while the previous one was still playing.
        let song: Song
        if let preloaded, preloaded.id == item.id {
            song = preloaded.song
        } else {
            song = try await mapErrors { try await Self.fetch(item) }
        }
        preloaded = nil

        try await mapErrors { try await Self.start(song) }
        nowPlaying = item
        // The queue was replaced wholesale, so anything that was behind the old
        // track went with it.
        nextUp = nil
        heardBeforeStretch = 0
        stretchStart = 0
    }

    // MARK: - The second entry

    /// What is queued directly behind ``nowPlaying``, if anything.
    ///
    /// **At most one, and only ever a song the caller has just judged.** This is
    /// the single place `ApplicationMusicPlayer` is allowed to advance by
    /// itself, and the length of this queue is the whole of what that permission
    /// costs: two entries can hand over gaplessly, and when the second one ends
    /// there is nothing behind it to wander into.
    public private(set) var nextUp: CatalogItem?

    /// Puts a judged song directly behind the one playing.
    ///
    /// The caller is expected to have asked ``FilteredCatalog/verdict(for:)``
    /// immediately beforehand, exactly as for ``play(_:)`` — and, unlike
    /// ``play(_:)``, to keep asking for as long as this sits here. A verdict
    /// taken at insertion is a verdict taken early; ``cancelNext()`` is how it
    /// gets taken back.
    public func enqueueNext(_ item: CatalogItem) async throws {
        guard item.id.kind == .song else {
            throw CatalogError.underlying(
                "Only songs can be queued; \(item.id.kind.rawValue) cannot."
            )
        }
        // Nothing to queue behind. Inserting `afterCurrentEntry` with no current
        // entry would be a queue of one that starts by itself.
        guard nowPlaying != nil else { return }
        guard nextUp == nil else { return }

        let song: Song
        if let preloaded, preloaded.id == item.id {
            song = preloaded.song
        } else {
            song = try await mapErrors { try await Self.fetch(item) }
        }

        try await mapErrors { try await Self.insert(song) }
        nextUp = item
    }

    private nonisolated static func insert(_ song: Song) async throws {
        try await ApplicationMusicPlayer.shared.queue.insert(
            song,
            position: .afterCurrentEntry
        )
    }

    /// Takes the queued song back out, leaving what is playing alone.
    ///
    /// What a verdict that has changed since insertion turns into. Everything
    /// but the current entry goes, rather than the one entry we think we added:
    /// the point of this call is that the queue must contain nothing unjudged,
    /// and filtering to the entry that is *playing* is the only version of it
    /// that is true even if our bookkeeping is wrong.
    public func cancelNext() {
        nextUp = nil
        guard let current = player.queue.currentEntry else { return }
        player.queue.entries = player.queue.entries.filter { $0.id == current.id }
    }

    /// Moves to the queued song now, rather than waiting for this one to end.
    ///
    /// What a kid pressing skip becomes when the next track is already sitting
    /// there judged and buffered. It reaches nothing ``enqueueNext(_:)`` did not
    /// already put within reach — the queue still holds exactly the two entries
    /// it held a moment ago — so it is a shortcut through the same handover and
    /// not a second way to advance.
    ///
    /// The caller still owes the adoption bookkeeping and the last verdict, the
    /// same as when the player gets there on its own.
    public func advanceToNextEntry() async throws {
        guard nextUp != nil else { return }
        try await mapErrors { try await Self.skipForward() }
    }

    private nonisolated static func skipForward() async throws {
        try await ApplicationMusicPlayer.shared.skipToNextEntry()
    }

    /// Takes over the song MusicKit has just advanced to by itself.
    ///
    /// Bookkeeping only — the audio is already playing by the time this is
    /// called, which is the trade the two-entry queue makes. It returns what is
    /// now playing so the caller can judge it again and cut it off if the answer
    /// has changed; see `KidPlayerModel.adoptHandover()`.
    @discardableResult
    public func adoptNext() -> CatalogItem? {
        guard let next = nextUp else { return nil }
        nextUp = nil
        nowPlaying = next
        heardBeforeStretch = 0
        stretchStart = 0
        return next
    }

    /// One song out of the catalog, ready to be queued.
    ///
    /// `nonisolated` so a preload does not have to hop to the main actor to make
    /// a network request, and so both callers share one definition of what
    /// "playable" means — the `playParameters` check below is the difference
    /// between a song and a row that will refuse, and having it in two places is
    /// how one of them ends up without it.
    private nonisolated static func fetch(_ item: CatalogItem) async throws -> Song {
        let request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: MusicItemID(item.id.rawValue)
        )
        let response = try await request.response()

        guard let song = response.items.first else {
            throw CatalogError.itemUnavailable(item.id)
        }

        // No play parameters means the storefront will not play it — a delisted
        // or region-restricted track. An allow list has to survive this.
        guard song.playParameters != nil else {
            throw CatalogError.itemUnavailable(item.id)
        }

        return song
    }

    /// Queues and starts, off any actor.
    ///
    /// `ApplicationMusicPlayer` predates strict concurrency: it is a
    /// non-`Sendable` class whose async methods are `nonisolated`, so calling
    /// them on an instance held by a `@MainActor` type counts as sending that
    /// instance across an isolation boundary. Reaching for `shared` here, in
    /// the same nonisolated context that uses it, means nothing crosses.
    private nonisolated static func start(_ song: Song) async throws {
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        try await player.prepareToPlay()
        try await player.play()
    }

    public func pause() async throws {
        player.pause()
    }

    public func resume() async throws {
        try await mapErrors { try await Self.resumePlayback() }
    }

    private nonisolated static func resumePlayback() async throws {
        try await ApplicationMusicPlayer.shared.play()
    }

    public func stop() async throws {
        player.stop()
        player.queue = ApplicationMusicPlayer.Queue()
        nowPlaying = nil
        nextUp = nil
        heardBeforeStretch = 0
        stretchStart = 0
    }

    /// Turns MusicKit's errors into ones the UI can write a sentence about.
    ///
    /// **What this does not yet do is recognise an outside restriction.**
    /// Screen Time's music restriction and Apple Music's own parental controls
    /// refuse playback, and the spec says such a refusal must be logged as
    /// `restrictedOutsideApp` and never attributed to a parent's own rule. Which
    /// error MusicKit actually throws in that case is unmeasured — it needs the
    /// real under-13 account on a device. Until then those land in
    /// ``CatalogError/underlying(_:)``, which is wrong but at least is not a
    /// confident lie about which rule fired.
    /// The closure is `@MainActor` so it can touch the player without that
    /// counting as sending a non-`Sendable` value across an isolation boundary.
    private func mapErrors<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw CatalogError.offline
            default:
                throw CatalogError.underlying(error.localizedDescription)
            }
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.underlying(error.localizedDescription)
        }
    }
}

#endif
