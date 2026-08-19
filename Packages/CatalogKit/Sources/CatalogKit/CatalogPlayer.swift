import Foundation

/// Narrow: no shuffle, autoplay, or radio; caller must keep re-judging the queue.
@MainActor
public protocol CatalogPlayer: AnyObject {
    /// Mechanism, not authority — caller must have just asked ``verdict(for:)``.
    func play(_ item: CatalogItem) async throws

    /// Best-effort prefetch, never throws — play(_:) still re-asks before sound.
    func preload(_ item: CatalogItem) async

    /// The one dangerous method: it can play unasked — re-judge, or cancelNext().
    func enqueueNext(_ item: CatalogItem) async throws

    /// Takes the queued song back out, leaving what is playing alone.
    func cancelNext()

    /// Skips ahead now; reaches nothing enqueueNext(_:) hadn't put in reach.
    func advanceToNextEntry() async throws

    /// Returns the song the player advanced to on its own, for one last judge.
    @discardableResult
    func adoptNext() -> CatalogItem?

    /// What is queued behind ``nowPlaying``. At most one item, always judged.
    var nextUp: CatalogItem? { get }

    func pause() async throws

    /// Never re-judges on resume — cutting mid-song would read as a fault.
    func resume() async throws

    /// Clears the queue; nothing plays again until asked for by name.
    func stop() async throws

    /// Not a door — reaches nowhere the verdict didn't allow; no re-judge.
    func seek(to seconds: TimeInterval) async

    /// A position, not an amount heard — those split apart once seeking arrived.
    var playbackTime: TimeInterval { get }

    /// Actual seconds heard, not position — a seek-back kid heard more than shown.
    var playbackSeconds: Int { get }

    /// What is loaded, or `nil` when nothing is.
    var nowPlaying: CatalogItem? { get }

    var status: PlaybackStatus { get }
}

/// `stopped` while loaded means it ended alone, unlike `paused` — why not a bool.
public enum PlaybackStatus: String, Sendable, Hashable, CaseIterable {
    case stopped
    case playing
    case paused

    /// Session lost to a call or another app — not policy, so the queue stays put.
    case interrupted
}

extension CatalogPlayer {
    public var isPlaying: Bool { status == .playing }

    /// A no-op is correct here — it costs a gap, not a wrong answer.
    public func preload(_ item: CatalogItem) async {}
}
