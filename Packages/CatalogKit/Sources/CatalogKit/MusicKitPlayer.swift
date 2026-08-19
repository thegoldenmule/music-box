#if canImport(MusicKit)

import Foundation
import MusicKit
import PolicyEngine

/// Uses the app queue, not system (leaks the parent's Up Next); forces macOS 14.
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
        // Transient; only reachable through controls this app doesn't offer.
        default: .playing
        }
    }

    public var playbackTime: TimeInterval {
        max(0, player.playbackTime)
    }

    /// Diagnostic only — unmapped states fold to playing, avoiding flicker.
    public var rawStatus: String {
        String(describing: player.state.playbackStatus)
    }

    /// Queue-entry id; nil once exhausted, even via the lock screen's next button.
    public var currentEntryID: String? {
        player.queue.currentEntry?.id
    }

    /// Banked time before this stretch; a seek is the only break in listening.
    private var heardBeforeStretch: TimeInterval = 0
    private var stretchStart: TimeInterval = 0

    public var playbackSeconds: Int {
        max(0, Int(heardBeforeStretch + max(0, playbackTime - stretchStart)))
    }

    public func seek(to seconds: TimeInterval) async {
        // Banks the ending stretch first, or dragging back erases minutes heard.
        heardBeforeStretch += max(0, playbackTime - stretchStart)
        let target = max(0, seconds)
        stretchStart = target
        player.playbackTime = target
    }

    /// One-slot cache, not queue; play(_:) asks by id, else stale goes unused.
    private var preloaded: (id: CatalogID, song: Song)?

    public func preload(_ item: CatalogItem) async {
        guard item.id.kind == .song, preloaded?.id != item.id else { return }
        // Failure is silent here; play(_:)'s real fetch reports what matters.
        guard let song = try? await Self.fetch(item) else { return }
        preloaded = (item.id, song)
    }

    public func play(_ item: CatalogItem) async throws {
        guard item.id.kind == .song else {
            // Songs only here; albums/playlists become queues — a policy question.
            throw CatalogError.underlying(
                "Only songs can be played directly; \(item.id.kind.rawValue) needs a queue."
            )
        }

        // Preload used only if matched — the round trip already ran last track.
        let song: Song
        if let preloaded, preloaded.id == item.id {
            song = preloaded.song
        } else {
            song = try await mapErrors { try await Self.fetch(item) }
        }
        preloaded = nil

        try await mapErrors { try await Self.start(song) }
        nowPlaying = item
        // Queue replaced wholesale; whatever was behind the old track is gone too.
        nextUp = nil
        heardBeforeStretch = 0
        stretchStart = 0
    }

    // MARK: - The second entry

    /// One at most, just-judged — caps the queue at two, nothing unvetted follows.
    public private(set) var nextUp: CatalogItem?

    /// Caller re-judges while queued; cancelNext() pulls back a changed verdict.
    public func enqueueNext(_ item: CatalogItem) async throws {
        guard item.id.kind == .song else {
            throw CatalogError.underlying(
                "Only songs can be queued; \(item.id.kind.rawValue) cannot."
            )
        }
        // No current entry means insert would start a queue of one by itself.
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

    /// Drops everything but current — safe even if our bookkeeping is wrong.
    public func cancelNext() {
        nextUp = nil
        guard let current = player.queue.currentEntry else { return }
        player.queue.entries = player.queue.entries.filter { $0.id == current.id }
    }

    /// A judged skip forward; caller still owes adoption bookkeeping, a verdict.
    public func advanceToNextEntry() async throws {
        guard nextUp != nil else { return }
        try await mapErrors { try await Self.skipForward() }
    }

    private nonisolated static func skipForward() async throws {
        try await ApplicationMusicPlayer.shared.skipToNextEntry()
    }

    /// Audio already plays; returns the item so the caller can re-judge it.
    @discardableResult
    public func adoptNext() -> CatalogItem? {
        guard let next = nextUp else { return nil }
        nextUp = nil
        nowPlaying = next
        heardBeforeStretch = 0
        stretchStart = 0
        return next
    }

    /// nonisolated: preload skips main actor; both share one playable check.
    private nonisolated static func fetch(_ item: CatalogItem) async throws -> Song {
        let request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: MusicItemID(item.id.rawValue)
        )
        let response = try await request.response()

        guard let song = response.items.first else {
            throw CatalogError.itemUnavailable(item.id)
        }

        // No play parameters: delisted or restricted; an allow list must survive.
        guard song.playParameters != nil else {
            throw CatalogError.itemUnavailable(item.id)
        }

        return song
    }

    /// Off-actor: predates strict concurrency; `shared` avoids an isolation send.
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

    /// Doesn't detect Screen Time restriction yet; the device error is unmeasured.
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
