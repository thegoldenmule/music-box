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

    public func play(_ item: CatalogItem) async throws {
        guard item.id.kind == .song else {
            // The slice plays songs. Albums and playlists become queues, which
            // is a policy question (every track judged, blocked ones skipped
            // rather than stopped on) and not a mechanical one.
            throw CatalogError.underlying(
                "Only songs can be played directly; \(item.id.kind.rawValue) needs a queue."
            )
        }

        let request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: MusicItemID(item.id.rawValue)
        )
        let response = try await mapErrors { try await request.response() }

        guard let song = response.items.first else {
            throw CatalogError.itemUnavailable(item.id)
        }

        // No play parameters means the storefront will not play it — a delisted
        // or region-restricted track. An allow list has to survive this.
        guard song.playParameters != nil else {
            throw CatalogError.itemUnavailable(item.id)
        }

        try await mapErrors { try await Self.start(song) }
        nowPlaying = item
        heardBeforeStretch = 0
        stretchStart = 0
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
