#if canImport(MusicKit)

import Foundation
import MusicKit
import PolicyEngine

/// ``CatalogPlayer`` on top of `ApplicationMusicPlayer` — the application queue,
/// not the system one: the system player shares state with the Music app, so a
/// kid's play would reorder the parent's Up Next and the parent's queue would
/// arrive here unvetted. This class is why the macOS floor is 14.0.
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

    /// The player's own word for what it is doing, unmapped. ``status`` folds the
    /// unrecognised into `playing` — right for a button, which must not flicker,
    /// and wrong for working out why a track did not advance; two of the five
    /// states here have no ``PlaybackStatus`` case. Diagnostic only: nothing decides on it.
    public var rawStatus: String {
        String(describing: player.state.playbackStatus)
    }

    /// The player's identifier for the queue entry it sits on — what
    /// `playbackStatus` cannot answer. Anything that moves it off the one queued
    /// song (track end, or the lock screen's next button, which bypasses the app)
    /// has run the queue out; which status results is a detail. `nil` when exhausted.
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
    /// Exactly one, and a cache rather than a queue: nothing plays from here
    /// without ``play(_:)`` asking for that item by name. A stale one — the kid
    /// tapped something else — is never matched and the next preload replaces it.
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

    /// What is queued behind ``nowPlaying`` — at most one, only ever a song the
    /// caller just judged. The single place `ApplicationMusicPlayer` may advance by
    /// itself, and the length is the whole price of that permission: two entries
    /// hand over gaplessly, and when the second ends there is nothing to wander into.
    public private(set) var nextUp: CatalogItem?

    /// Puts a judged song directly behind the one playing. The caller is expected
    /// to have asked ``FilteredCatalog/verdict(for:)`` immediately beforehand, as
    /// for ``play(_:)`` — and, unlike ``play(_:)``, to keep asking while this sits
    /// here: a verdict at insertion is taken early, and ``cancelNext()`` takes it back.
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

    /// Takes the queued song back out, leaving what is playing alone — what a
    /// verdict changed since insertion turns into. Everything but the current
    /// entry goes, not "the one we added": the queue must hold nothing unjudged,
    /// and keeping only the *playing* entry is true even when our bookkeeping is wrong.
    public func cancelNext() {
        nextUp = nil
        guard let current = player.queue.currentEntry else { return }
        player.queue.entries = player.queue.entries.filter { $0.id == current.id }
    }

    /// Moves to the queued song immediately — a kid's skip when the next track
    /// is already judged and buffered. Reaches nothing ``enqueueNext(_:)`` did
    /// not already put within reach, so it is a shortcut through the same
    /// handover; the caller still owes the adoption bookkeeping and final verdict.
    public func advanceToNextEntry() async throws {
        guard nextUp != nil else { return }
        try await mapErrors { try await Self.skipForward() }
    }

    private nonisolated static func skipForward() async throws {
        try await ApplicationMusicPlayer.shared.skipToNextEntry()
    }

    /// Takes over the song MusicKit has just advanced to by itself. Bookkeeping
    /// only — audio is already playing, the trade the two-entry queue makes.
    /// Returns what is now playing so the caller can re-judge and cut it off if
    /// the answer changed; see `KidPlayerModel.adoptHandover()`.
    @discardableResult
    public func adoptNext() -> CatalogItem? {
        guard let next = nextUp else { return nil }
        nextUp = nil
        nowPlaying = next
        heardBeforeStretch = 0
        stretchStart = 0
        return next
    }

    /// One song out of the catalog, ready to be queued. `nonisolated` so a
    /// preload need not hop to the main actor, and so both callers share one
    /// "playable" check (`playParameters`) rather than each keeping their own,
    /// which is how one of them ends up without it.
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

    /// Queues and starts, off any actor. `ApplicationMusicPlayer` predates
    /// strict concurrency — a non-`Sendable` class with `nonisolated` async
    /// methods, so calling them on a `@MainActor`-held instance would send it
    /// across an isolation boundary. Reaching for `shared` here avoids that.
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

    /// Turns MusicKit's errors into ones the UI can write a sentence about. Doesn't yet handle
    /// outside restriction (Screen Time, parental controls): spec wants `restrictedOutsideApp`,
    /// real error unmeasured without a device, so it lands in ``CatalogError/underlying(_:)``.
    /// `@MainActor` keeps the closure off the isolation boundary.
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
