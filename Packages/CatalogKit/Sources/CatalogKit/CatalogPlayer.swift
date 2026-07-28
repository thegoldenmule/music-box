import Foundation

/// Plays one item at a time.
///
/// A protocol for the same reason ``CatalogSource`` is one: the app above this
/// layer never sees a MusicKit type, and playback has to be testable without a
/// device, a subscription, or a signed-in account.
///
/// **Deliberately narrow.** There is no `skip`, no shuffle and no repeat here,
/// and there will never be autoplay past the end of a queue or radio — both
/// reach unvetted material. What this can do is play a thing the policy engine
/// has already allowed, hold exactly one more behind it, and stop.
///
/// **The one behind it is a considered exception.** Handing the player a second
/// entry is the only way two tracks join without a gap, and it means the player
/// advances once without being asked. The rule that replaces "never advance by
/// yourself" is narrower and has to be kept by the caller: nothing is inserted
/// that has not just been judged, the verdict is re-taken for as long as it sits
/// there, and it is pulled back out the moment the answer changes. See
/// ``enqueueNext(_:)``.
///
/// `@MainActor` because the underlying player is, and because everything that
/// drives it is a view.
@MainActor
public protocol CatalogPlayer: AnyObject {
    /// Starts this item from the beginning.
    ///
    /// The caller is expected to have asked ``FilteredCatalog/verdict(for:)``
    /// immediately beforehand. This does not re-judge: it is the mechanism, not
    /// the authority.
    func play(_ item: CatalogItem) async throws

    /// Fetches what ``play(_:)`` would need, without playing anything.
    ///
    /// **Not a queue, and not a decision.** The gap between two tracks is mostly
    /// a catalog round trip that only starts once the previous song has ended;
    /// this is that round trip, moved to while there is still music playing. It
    /// loads *one* item and leaves the player exactly as it found it, so nothing
    /// here can advance, and the policy engine is still asked immediately before
    /// the sound starts — a preloaded song that has since been denied is thrown
    /// away by ``play(_:)``'s caller like any other.
    ///
    /// Best-effort by contract: it does not throw, and a conformance is free to
    /// do nothing. A caller must never await it on the path to playing.
    func preload(_ item: CatalogItem) async

    /// Puts a judged song directly behind the one playing, so the two join
    /// without a gap.
    ///
    /// **This is the seam's one dangerous method**, and the danger is entirely
    /// in *when* the verdict was taken rather than whether it was. Everything
    /// else here acts on a song the caller judged a moment ago; this one acts on
    /// a song that will start playing some seconds later, on its own, with no
    /// further call. The caller owes it three things: judge immediately before
    /// inserting, keep judging while it is queued, and call ``cancelNext()`` if
    /// the answer changes.
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

    /// Resumes a paused item.
    ///
    /// Deliberately does **not** re-judge. The verdict that started this track
    /// still stands, and a policy change mid-song lands on the next evaluation
    /// — cutting out halfway through reads as a fault rather than a rule.
    func resume() async throws

    /// Stops and clears the queue. Nothing plays after this until something is
    /// asked for by name.
    func stop() async throws

    /// Moves the playhead within the current item.
    ///
    /// Not a door: it reaches nowhere the verdict that started this track did
    /// not already allow, which is why it is the one control added to play,
    /// pause and skip. It deliberately does **not** re-judge, for the same
    /// reason ``resume()`` does not — a policy change lands on the next
    /// evaluation rather than cutting out halfway through.
    func seek(to seconds: TimeInterval) async

    /// Where the playhead is, for a scrubber to draw.
    ///
    /// This is a **position**, not an amount heard. The two stopped being the
    /// same thing when seeking arrived: see ``playbackSeconds``.
    var playbackTime: TimeInterval { get }

    /// Seconds of the current item actually heard, for the play event's
    /// `secondsPlayed`.
    ///
    /// **Not the same as ``playbackTime``.** A kid who listens for a minute and
    /// then drags back to the start is at position 0:10 having heard 1:10, and
    /// a report that reads the position tells their parent they played ten
    /// seconds of it. Conformances accumulate across seeks; the sum can exceed
    /// the track's duration, which is correct — a chorus played four times was
    /// heard four times.
    var playbackSeconds: Int { get }

    /// What is loaded, or `nil` when nothing is.
    var nowPlaying: CatalogItem? { get }

    var status: PlaybackStatus { get }
}

/// What the player is doing.
///
/// `stopped` while something is still loaded is how a caller learns a track
/// ended on its own. The difference between that and `paused` is the difference
/// between advancing a queue and leaving it where it is — which is why this is
/// a status rather than the `isPlaying` boolean it replaces.
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
