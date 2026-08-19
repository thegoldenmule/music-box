import Foundation

/// Plays one item at a time — deliberately narrow: no shuffle, no repeat, never autoplay or radio,
/// both reach unvetted material. Holds one judged item behind what's playing for a gapless join;
/// the caller must judge before inserting, keep judging while queued, and retract on a changed
/// answer — see ``enqueueNext(_:)``.
@MainActor
public protocol CatalogPlayer: AnyObject {
    /// Starts this item from the beginning. The caller is expected to have
    /// asked ``FilteredCatalog/verdict(for:)`` immediately beforehand.
    /// This does not re-judge: it is the mechanism, not the authority.
    func play(_ item: CatalogItem) async throws

    /// Fetches what ``play(_:)`` needs, without playing anything: moves the catalog round trip to while playing, loads one
    /// item, leaves the player untouched — the engine is still asked before sound starts, so a since-denied preload is
    /// discarded like any other. Best-effort: never throws, may do nothing, never awaited on the play path.
    func preload(_ item: CatalogItem) async

    /// Puts a judged song directly behind the one playing, for a gapless join. The seam's one dangerous method:
    /// everything else acts on a song judged a moment ago, this on a song that starts playing seconds later, unasked.
    /// Owed: judge before inserting, keep judging while queued, call ``cancelNext()`` if the answer changes.
    func enqueueNext(_ item: CatalogItem) async throws

    /// Takes the queued song back out, leaving what is playing alone.
    func cancelNext()

    /// Moves to the queued song now instead of when this one ends. Reaches
    /// nothing ``enqueueNext(_:)`` had not already put within reach.
    func advanceToNextEntry() async throws

    /// Takes over the song the player advanced to on its own, returning it so
    /// the caller can judge it one last time.
    @discardableResult
    func adoptNext() -> CatalogItem?

    /// What is queued behind ``nowPlaying``. At most one item, always judged.
    var nextUp: CatalogItem? { get }

    func pause() async throws

    /// Resumes a paused item. Deliberately does not re-judge: the verdict that
    /// started this track still stands, and a policy change mid-song lands on the
    /// next evaluation — cutting out halfway through reads as a fault, not a rule.
    func resume() async throws

    /// Stops and clears the queue. Nothing plays after this until something is
    /// asked for by name.
    func stop() async throws

    /// Moves the playhead within the current item. Not a door: reaches nowhere the starting
    /// verdict didn't already allow, why it's the one control added to play, pause and
    /// skip. Deliberately does not re-judge, for the same reason ``resume()`` does not.
    func seek(to seconds: TimeInterval) async

    /// Where the playhead is, for a scrubber to draw.
    ///
    /// This is a **position**, not an amount heard. The two stopped being the
    /// same thing when seeking arrived: see ``playbackSeconds``.
    var playbackTime: TimeInterval { get }

    /// Seconds actually heard, for the play event's `secondsPlayed`. Not ``playbackTime``: a kid who listens a minute
    /// then drags back to the start sits at 0:10 having heard 1:10; reading position would tell a parent ten seconds.
    /// Accumulates across seeks — a chorus played four times was heard four times.
    var playbackSeconds: Int { get }

    /// What is loaded, or `nil` when nothing is.
    var nowPlaying: CatalogItem? { get }

    var status: PlaybackStatus { get }
}

/// What the player is doing. `stopped` while something is still loaded is how a caller learns
/// a track ended on its own — the difference from `paused` is advancing a queue versus
/// leaving it put, why this is a status rather than the `isPlaying` boolean it replaces.
public enum PlaybackStatus: String, Sendable, Hashable, CaseIterable {
    case stopped
    case playing
    case paused

    /// Something outside took the audio session — a call, another app. Not a
    /// policy decision and not the end of a track, so the queue stays put.
    case interrupted
}

extension CatalogPlayer {
    public var isPlaying: Bool { status == .playing }

    /// Doing nothing is a correct implementation: it costs a gap, not a wrong
    /// answer. Only the MusicKit conformance has a round trip worth moving.
    public func preload(_ item: CatalogItem) async {}
}
