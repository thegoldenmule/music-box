import CatalogKit
import FamilyStore
import Foundation
import KidLibrary
import SwiftUI

/// The kid's queue and what is playing.
///
/// **The queue lives here, not in MusicKit.** `MusicKitPlayer` is handed one
/// song at a time on purpose: if the whole album went into
/// `ApplicationMusicPlayer` it would advance by itself, and every advance past
/// the first track would happen without the policy engine being asked. Holding
/// the queue here means every track is judged immediately before it plays,
/// including the ones nobody tapped.
///
/// It also gets autoplay-past-the-end for free. When this queue runs out,
/// playback stops — there is nothing for MusicKit to wander into.
///
/// **The queue outlives the process.** It is written to ``PlayQueueStore`` on
/// every change and read back in `init`, so the app opens with the bar already
/// showing what the kid was on and one tap away from carrying on. Restoring is
/// not trusting: nothing that comes off disk plays without going through
/// ``Session/play(_:origin:)`` and its verdict, and ``revalidate()`` re-judges
/// the whole queue on the way in so a song denied since last night is gone from
/// the bar rather than sitting there waiting to refuse.
@MainActor
@Observable
final class KidPlayerModel {
    struct Entry: Identifiable {
        let item: CatalogItem
        let origin: PlaybackOrigin
        var id: CatalogID { item.id }
    }

    private(set) var queue: [Entry] = []
    private(set) var index = 0
    private(set) var isBusy = false

    /// What the player is doing, **mirrored here rather than read through**.
    ///
    /// `MusicKitPlayer` is a plain class wrapping `ApplicationMusicPlayer`, so
    /// nothing about it is observable — a view asking it directly renders once
    /// and then never hears about a change. That is why the play/pause button
    /// used to show the wrong thing: the state was right and the view had no
    /// reason to redraw. The poll below keeps this in step.
    private(set) var status: PlaybackStatus = .stopped

    /// The one message a kid may ever see about a block, and only for a track
    /// filtered out of something they were already allowed to play.
    private(set) var message: String?

    /// Where the playhead is, mirrored here for the same reason ``status`` is:
    /// nothing about `MusicKitPlayer` is observable, so a scrubber reading it
    /// directly would draw once and then sit still. Kept current by the poll
    /// below, which already runs whenever anything is loaded — the full-screen
    /// player costs no extra timer, and the bar keeps working when it is closed.
    private(set) var playbackTime: TimeInterval = 0

    var current: Entry? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    /// How long the current track is, or `nil` when the catalog did not say.
    ///
    /// It comes back with the song itself from every path that builds a
    /// `CatalogItem`, so in practice this is populated — but a scrubber with no
    /// end to scrub to is meaningless, and the full-screen player draws elapsed
    /// time alone rather than guessing at a length.
    var duration: TimeInterval? {
        guard let seconds = current?.item.duration, seconds > 0 else { return nil }
        return seconds
    }

    var isPlaying: Bool { status == .playing }

    private let session: Session
    private var watchdog: Task<Void, Never>?

    /// Whether this entry has ever actually been heard playing.
    ///
    /// Without it, `stopped` right after asking MusicKit to play — which is
    /// simply what the player reports for the moment before it starts — reads
    /// as "the track ended" and skips instantly. That was the first-tap-does-
    /// nothing bug: tapping a song moved straight past it to the next one.
    private var hasStartedCurrent = false

    /// Whether the kid is the reason this is not playing.
    ///
    /// The end of a track and a pause both stop the audio, and the difference
    /// between them is not always in what the player reports — see
    /// ``hasEnded``. This is the half of it we know for certain, because we did
    /// it: a kid holding the app paused on the last ten seconds of a song must
    /// not have it advance out from under them.
    private var pausedByKid = false

    /// The furthest into the current track the playhead has been seen.
    ///
    /// Rises with the playhead and is reset by a new track or a seek — a drag
    /// back to the middle un-listens the end, which is exactly what the kid just
    /// did. It is what lets "the player is no longer playing" be read as an
    /// ending in one place and a pause in another — see ``hasEnded``.
    private var furthest: TimeInterval = 0

    /// How long the playhead has sat still.
    ///
    /// A track that is over but that the player still calls `playing` is
    /// invisible to any test on the status. It is not invisible to this one.
    ///
    /// **Seconds rather than a count of polls**, because the poll interval is
    /// not fixed — it tightens near the end of a track. Counting polls made this
    /// quietly wrong at the one moment it matters: two fast polls can straddle a
    /// single update of `playbackTime`, which would read as a stall and cut the
    /// last seconds off every song.
    private var stalledFor: TimeInterval = 0

    /// How long the player has said it was playing this track.
    ///
    /// The backstop, for the case where the playhead is not merely ambiguous but
    /// useless — a `playbackTime` that never moves would leave ``furthest`` at
    /// zero and every test built on it false forever. Time spent playing is a
    /// clock nothing but this file owns.
    ///
    /// Reset by a seek rather than left to run, because a kid dragging back to
    /// the start has not listened to four minutes of a four-minute song, and a
    /// counter that thought so would cut the track off.
    private var playedSeconds: TimeInterval = 0

    /// The queue entry MusicKit was on when this track started playing.
    ///
    /// Taken from the player rather than from our own queue, because the point
    /// of it is to notice when the two stop agreeing. Latched on the first poll
    /// that reports one — right after `play()` returns there may not be an entry
    /// yet, and treating that moment as a departure would skip every track the
    /// instant it started, which is the shape of bug this file has had once
    /// already.
    private var loadedEntry: String?

    /// Where the current track was up to when the app last closed.
    ///
    /// Consumed by the first play after a restore and cleared by anything that
    /// changes which song is loaded — it belongs to one entry, and carrying it
    /// to the next would drop a kid thirty seconds into a track they have not
    /// heard.
    private var resumeFrom: TimeInterval?

    /// Which entry of ``queue`` is sitting in MusicKit behind the current one.
    ///
    /// `nil` whenever nothing is queued there, which is most of a track. It is
    /// an index rather than a flag because the handover has to know *what* it is
    /// adopting, and asking the player would be trusting the thing being
    /// checked.
    private var enqueued: Int?

    /// Whose queue this is.
    ///
    /// Read at every write instead of `session.kid.id`, because the two are not
    /// the same thing for the moment a kid switch takes. The switch changes the
    /// session's kid first and the player is told afterwards, so a save in
    /// between — the watchdog's periodic one is enough — would file one child's
    /// album under the other's name. Keeping the owner beside the queue means
    /// the answer travels with what is being written rather than with the app's
    /// idea of who is using it.
    private var owner: UUID

    init(session: Session) {
        self.session = session
        owner = session.kid.id
        restore()
    }

    // MARK: - Starting

    /// Plays one item, with the rest of its surface behind it.
    ///
    /// The album, the artist's song list, the search results, the playlist,
    /// the shelf — whatever list the tap came from is the queue, and the tapped
    /// song is where in it playback starts. That is the whole of "queue the rest
    /// of the album": the screen already knows what it is showing, so it hands
    /// it over rather than the player going looking.
    ///
    /// `queue` is already filtered — blocked items never enter it. That is not
    /// a substitute for the re-check, it is in addition to one: the list was
    /// filtered when the screen drew, and a parent may have denied something in
    /// the meantime.
    ///
    /// **A tapped song that is not in the list still plays, and plays first.**
    /// The two are handed over separately and nothing guarantees they agree —
    /// a row drawn from a list the screen has since reloaded is enough. Falling
    /// back to index zero, which is what a missing `firstIndex` used to do,
    /// answers a tap on one song by playing a different one.
    func play(_ item: CatalogItem, from queue: [CatalogItem], origin: PlaybackOrigin) async {
        let entries = queue.map { Entry(item: $0, origin: origin) }
        resumeFrom = nil
        enqueued = nil
        // A queue made now belongs to whoever is playing now. Nothing else moves
        // this, which is what keeps a switch from rewriting the old kid's slot.
        owner = session.kid.id

        if let start = entries.firstIndex(where: { $0.item.id == item.id }) {
            self.queue = entries
            index = start
        } else {
            self.queue = [Entry(item: item, origin: origin)] + entries
            index = 0
        }
        await playCurrent()
    }

    // MARK: - Controls
    //
    // Play, pause, skip. That is the entire surface: no stop, no scrubber, no
    // shuffle, no repeat, no station. The absence of a stop is why a play has
    // to be flushed from several places — see `Session.flushCurrentPlay`.

    /// Play, pause, or — when nothing is loaded into MusicKit — start.
    ///
    /// The third branch is what a restored queue lands on. Coming back to the
    /// app leaves this type holding a song and MusicKit holding nothing, so the
    /// button says play and pressing it starts the track the kid left, from
    /// where they left it. Nothing about that path is special-cased: it is the
    /// same ``playCurrent()`` a tap on a row goes through, verdict and all.
    func togglePlayPause() async {
        guard current != nil else { return }
        do {
            if isPlaying {
                pausedByKid = true
                try await session.player.pause()
                syncStatus()
                // Written here rather than only on the way out, because a pause
                // is the most likely last thing to happen before the app is
                // closed — and the playhead is worth keeping.
                save()
                return
            } else if status == .paused, session.player.nowPlaying != nil {
                pausedByKid = false
                try await session.resume()
            } else {
                await playCurrent()
                return
            }
            syncStatus()
        } catch {
            message = Session.kidMessage(for: error)
        }
    }

    /// Moves the playhead inside the track already playing.
    ///
    /// The fourth control, and the only one that has ever been added to the
    /// three above. It is not a door — it reaches nowhere the verdict that
    /// started this track did not already allow — which is the test every
    /// control on this screen has to pass.
    ///
    /// ``playbackTime`` is set here rather than left to the next poll: half a
    /// second of the thumb springing back to where it was is the whole
    /// difference between a scrubber that works and one that fights.
    ///
    /// On a queue that has been restored and not yet started, it moves where
    /// playback *will* begin rather than where it is. MusicKit is holding
    /// nothing at that point, so seeking it would go nowhere and the stored
    /// position would then overrule the drag the moment the kid pressed play —
    /// a scrubber that visibly snaps back is worse than one that is absent.
    func seek(to seconds: TimeInterval) async {
        guard current != nil else { return }
        let target = min(max(0, seconds), duration ?? seconds)

        if session.player.nowPlaying == nil {
            resumeFrom = target
        } else {
            await session.player.seek(to: target)
        }
        playbackTime = target
        // Both clocks the end-of-track test keeps move with the drag. Leaving
        // them behind would have a drag backwards read as a track already
        // listened to, and a drag forwards read as one that never got there.
        furthest = target
        playedSeconds = target
        stalledFor = 0
    }

    /// Skip forward. Stops at the end rather than wandering into anything.
    ///
    /// When the next track is already queued and buffered — which it is for the
    /// last seconds of every song — this goes through the handover rather than
    /// tearing the queue down and building it again. Same two entries, same last
    /// verdict, no gap.
    func skip() async {
        guard !queue.isEmpty else { return }

        if enqueued == index + 1, session.player.nextUp != nil {
            try? await session.player.advanceToNextEntry()
            await adoptHandover()
            return
        }

        session.flushCurrentPlay()
        resumeFrom = nil
        index += 1
        guard queue.indices.contains(index) else {
            await stop()
            return
        }
        await playCurrent()
    }

    func stop() async {
        watchdog?.cancel()
        watchdog = nil
        // `session.stop()` empties MusicKit's queue, so the entry behind the
        // current one goes with it — but the index that named it lives here.
        enqueued = nil
        await session.stop()
        queue = []
        index = 0
        status = .stopped
        resetTrackState()
        // An empty queue clears the slot rather than storing an empty one, so
        // the next launch opens with no bar — which is what running out of
        // queue means.
        save()
    }

    /// Writes the play in progress without disturbing playback.
    ///
    /// Called when the app goes to the background. With no stop control, a kid
    /// who plays one song and puts the phone down would otherwise never produce
    /// a play event at all — which is exactly why recents stayed empty.
    ///
    /// It is also the last moment before the app is closed that is guaranteed to
    /// run, so the queue goes down here too. The periodic write in the watchdog
    /// covers the case this one does not: a crash, or a device that runs out of
    /// battery mid-song.
    func flush() {
        session.flushCurrentPlay()
        save()
    }

    // MARK: - Between launches

    /// Puts back what was playing, without playing it.
    ///
    /// Called from `init`, so the bar is populated on the first frame rather
    /// than after a round trip — which is the whole point of storing the items
    /// and not just their identifiers. ``status`` stays `stopped`: MusicKit is
    /// holding nothing, and the kid pressing play is what loads it.
    ///
    /// The watchdog is deliberately not started. It advances on a stopped
    /// player, and a restored queue is a stopped player that has not begun.
    /// Whether the stored playhead is worth putting back is decided here rather
    /// than at play time, because it is a question about the stored value: a few
    /// seconds in is not a place anyone was, a few seconds from the end is a
    /// song they finished, and a song the catalog gave no length for has nothing
    /// to check either against. What survives that is a position the kid was
    /// actually at — and a later drag on the scrubber replaces it outright,
    /// because that one is a choice they just made.
    private func restore() {
        guard let saved = session.playQueues.queue(for: owner) else { return }
        queue = saved.entries.map { Entry(item: $0.item, origin: $0.origin) }
        index = saved.index

        if saved.elapsed > 3, let length = duration, saved.elapsed < length - 5 {
            resumeFrom = saved.elapsed
        }
    }

    /// Re-judges a restored queue against the policy as it stands now.
    ///
    /// A queue is stored state, and stored state is **filtered at render time**
    /// — the rule the Recent shelf and the favorites shelf both work under. A
    /// parent can deny an artist overnight, and the bar must not open showing
    /// their track. The verdict is what stops it playing; this is what stops it
    /// being on screen at all.
    ///
    /// Local, in the ordinary case: entries were stored with their ancestry, so
    /// nothing here goes to the network. A verdict that cannot be reached leaves
    /// the entry alone rather than dropping it — playback asks again anyway, and
    /// an offline launch that emptied the bar would look like the queue was lost.
    ///
    /// **Nothing is logged.** A blocked entry here is a stored row that is still
    /// on disk, the same shape as a blocked favorite, so the report can find it
    /// whenever it is asked; writing a block on every launch would drown the
    /// parent's report in one kid's Tuesday.
    func revalidate() async {
        guard !queue.isEmpty, status == .stopped, !hasStartedCurrent else { return }

        var allowed: [Entry] = []
        for entry in queue {
            guard let verdict = try? await session.catalog.verdict(for: entry.item) else {
                allowed.append(entry)
                continue
            }
            if verdict.isAllowed { allowed.append(entry) }
        }

        guard allowed.count != queue.count else { return }

        // Falling back to the front of what is left is right *here* and would
        // not be in general: a stored queue begins at the playhead — nothing
        // behind it is kept — so the first survivor is the next thing the kid
        // was going to hear, never something they already have. If the song
        // they left on is one of the ones that went, the stored playhead
        // belongs to it and goes with it.
        let wasCurrent = current?.item.id
        queue = allowed
        index = allowed.firstIndex { $0.item.id == wasCurrent } ?? 0
        if current?.item.id != wasCurrent { resumeFrom = nil }
        save()
    }

    /// Re-judges **what is playing right now**, the moment the policy changes.
    ///
    /// ``revalidate()`` is the launch-time pass and deliberately refuses to run
    /// on a live player — `status == .stopped, !hasStartedCurrent`. The queued
    /// entry is covered by ``pollQueuedItem()`` on every watchdog tick. Between
    /// them they left one hole, and it was the obvious one: a parent who denies
    /// the song their child is playing, and watches it play to the end. That was
    /// true on one device with nothing synced, and it is where a deny arriving
    /// from another parent's phone will land.
    ///
    /// Synchronous verdict, for the same reason ``pollQueuedItem()`` uses it: a
    /// queued entry carries its ancestry, so this is an indexed lookup rather
    /// than a round trip, and it can run on a parent's keystroke.
    ///
    /// **An unjudgeable answer leaves the track alone.** `.unknown` means the
    /// ancestry is not there to judge with, not that anything is wrong — the
    /// track was judged properly when it started, and stopping a child's music
    /// because a lineage went missing is the wrong direction to fail in here.
    /// The narrow case this must catch is a verdict that *changed*.
    func revalidatePlaying() async {
        // The entry behind this one is polled on a tick that only runs while the
        // watchdog does, so a paused player would keep a now-denied song queued.
        pollQueuedItem()

        guard queue.indices.contains(index) else { return }
        let entry = queue[index]
        guard case .blocked(let reason) = session.queuedVerdict(for: entry.item) else { return }

        // Silence first, for the reason ``adoptHandover()`` gives: everything
        // else here can wait a turn, a denied song coming out of the speaker
        // cannot, and letting `skip()` replace the queue would leave it playing
        // for as long as the next track takes to load.
        try? await session.player.pause()
        session.refuseAdopted(entry.item, reason: reason, origin: entry.origin)
        message = nil
        await skip()
    }

    /// Writes the queue down, or clears it when there is nothing to come back to.
    ///
    /// Fire-and-forget in the ``EventLog`` sense — no failure is surfaced,
    /// because the cost of a queue that did not save is an app that opens empty,
    /// and there is nothing a kid could do with the news.
    private func save() {
        session.playQueues.save(
            PlayQueue(
                entries: queue.map { PlayQueue.Entry(item: $0.item, origin: $0.origin) },
                index: index,
                elapsed: playbackTime
            ),
            for: owner
        )
    }

    /// Hands the player over to another kid.
    ///
    /// Called when the admin switches kids. The audio stops rather than carrying
    /// on under a new name: what is playing was judged against the policy of the
    /// child who is no longer using the app, and the play event it would write
    /// belongs to them. ``Session/switchTo(_:)`` flushes that event before the
    /// switch, which is why stopping here does not misfile it.
    func switchedKid() async {
        watchdog?.cancel()
        watchdog = nil
        // Where they were up to, under the name it belongs to, before anything
        // is torn down. A child handed the app back should find their album
        // where they left it and not at the top of the track.
        save()
        enqueued = nil
        await session.stop()
        owner = session.kid.id
        queue = []
        index = 0
        status = .stopped
        message = nil
        resetTrackState()
        // Not `save()` — the other child's queue is still theirs and stays on
        // disk. This reads the new kid's.
        restore()
    }

    // MARK: - The re-check

    /// Plays whatever `index` points at, asking the engine again first.
    private func playCurrent() async {
        guard let entry = current else { return }

        isBusy = true
        defer { isBusy = false }
        // `resumeFrom` is the one piece of per-track state this must not clear:
        // it was set for the entry about to be played, and it is consumed a few
        // lines below.
        let resuming = resumeFrom
        resetTrackState()
        resumeFrom = resuming
        // Whatever was queued behind the old track goes with it — `play` replaces
        // MusicKit's queue wholesale.
        enqueued = nil

        do {
            try await session.play(entry.item, origin: entry.origin)
            message = nil
            syncStatus()
            await resumeIfRestored()
            startWatchdog()
            save()
            preloadNext()
        } catch is Session.Refused {
            // Already logged by Session.play, with its reason. Skipped rather
            // than surfaced, except from a playlist where the kid was already
            // promised the playlist and a silent gap reads as a fault. Their own
            // playlist counts double: they put the song there themselves.
            switch entry.origin {
            // A suggested playlist counts with the other two: the kid was shown
            // a list and pressed play on it, so a silent gap reads as a fault
            // rather than as a wall.
            case .playlist, .kidPlaylist, .suggestedPlaylist:
                message = "Skipping this one — let's try the next."
            // A suggested *tile* is a shelf, like the home screen. Nothing was
            // promised beyond the one thing they tapped.
            case .home, .search, .browse, .suggestion:
                break
            }
            await skip()
        } catch CatalogError.itemUnavailable {
            // Gone from the catalog. Skipping is right: an allow list has to
            // survive a delisting without stranding the kid on a dead tile.
            await skip()
        } catch {
            // Everything else is surfaced. Silently skipping on any error made
            // every playback failure invisible and burned through the queue
            // looking for one that worked.
            message = Session.kidMessage(for: error)
            status = .stopped
            // Still written down: the queue is intact and the kid can press play
            // again, now or after relaunching, and the failure was the network's
            // rather than this entry's.
            save()
        }
    }

    // MARK: - The handover

    /// How long before the end of a track the next one is handed to MusicKit.
    ///
    /// **The exposure window, in seconds.** Everything between this point and
    /// the handover is time in which a song has been judged and not yet heard,
    /// so a parent's deny landing inside it is racing the re-check in
    /// ``pollQueuedItem()``. Twelve seconds is enough for the player to have the
    /// next track buffered and ready to join without a gap, and short enough
    /// that the window is a sentence long rather than a song long — handing it
    /// over at the *start* of the previous track, which is where the preload
    /// happens, would have made it four minutes.
    private static let enqueueLead: TimeInterval = 12

    /// Hands the next track to MusicKit, once, near the end of this one.
    ///
    /// Judged immediately before insertion by ``Session/enqueueNext(_:)``. A
    /// refusal is silent and simply leaves nothing queued: the ordinary
    /// end-of-track path will reach that song, judge it again, log the block and
    /// skip it, which is the behaviour it has always had.
    private func enqueueNextIfDue() async {
        guard enqueued == nil, status == .playing, let duration else { return }
        guard playbackTime >= duration - Self.enqueueLead else { return }

        let target = index + 1
        guard queue.indices.contains(target) else { return }

        // Nothing is queued that cannot be *re*-judged locally. An item with no
        // ancestry can only be judged by going to the network, which the poll
        // will not do — so it would be cancelled on the very next tick and
        // re-inserted on the one after, forever. Refusing it here costs that
        // song a gapless join and keeps the rule that everything sitting in
        // MusicKit's queue is being watched.
        guard case .allowed = session.queuedVerdict(for: queue[target].item) else { return }

        if await session.enqueueNext(queue[target].item) {
            enqueued = target
        }
    }

    /// Re-asks the engine about the song already queued, every poll.
    ///
    /// This is what makes moving the check to insertion survivable. The verdict
    /// taken at insertion is only as good as the moment it was taken, and the
    /// player will act on it seconds later with nobody else in the loop — so it
    /// is taken again, continuously, right up to the handover. A changed answer
    /// pulls the song straight back out, before it is heard rather than after.
    ///
    /// Local by construction: a queued item carries its ancestry, so this is an
    /// indexed lookup and not a round trip. An item that cannot be judged
    /// without one is dropped rather than left in on a guess.
    private func pollQueuedItem() {
        guard let target = enqueued, queue.indices.contains(target) else { return }
        guard case .allowed = session.queuedVerdict(for: queue[target].item) else {
            session.cancelNext()
            enqueued = nil
            return
        }
    }

    /// Takes over the track MusicKit advanced to by itself.
    ///
    /// The audio is already playing when this runs — that is the whole cost of
    /// the two-entry queue, and no amount of care here removes it. What it can
    /// do is be the last check rather than no check: the song is judged once
    /// more, and an answer that has changed since insertion cuts it off and logs
    /// it as something the child heard.
    private func adoptHandover() async {
        guard let target = enqueued, queue.indices.contains(target) else {
            // The player moved somewhere we did not put it. Clear whatever it is
            // holding and let the ordinary path re-establish the queue.
            session.cancelNext()
            enqueued = nil
            await skip()
            return
        }

        // Before `adoptNext` changes what `nowPlaying` is, because that is what
        // the previous track's play event is written from.
        session.flushCurrentPlay()

        let entry = queue[target]
        index = target
        enqueued = nil
        resetTrackState()

        guard session.adoptNext(origin: entry.origin) != nil else {
            // The player did not actually move, so there is nothing to adopt.
            // Loading the track ourselves costs the gap this was avoiding and is
            // otherwise identical — including the verdict.
            await playCurrent()
            return
        }

        // The last verdict, and the only one in the app taken while the song it
        // is about is already audible.
        switch session.queuedVerdict(for: entry.item) {
        case .blocked(let reason):
            // Silence first. Everything else here can wait a turn; a denied song
            // coming out of the speaker cannot, and letting `skip()` replace the
            // queue would leave it playing for as long as the next track takes
            // to load.
            try? await session.player.pause()
            session.refuseAdopted(entry.item, reason: reason, origin: entry.origin)
            message = nil
            await skip()
            return
        case .unknown:
            // Not judgeable without the network, and already playing. Stop it
            // and go the ordinary way, which asks properly and waits for the
            // answer. This should be unreachable — nothing is queued that cannot
            // be re-judged — and is here because "unreachable" is a claim about
            // today's callers.
            try? await session.player.pause()
            await playCurrent()
            return
        case .allowed:
            break
        }

        message = nil
        // Everything a track normally does on starting, minus starting it.
        await session.noteVisit(entry.item, manner: .played)
        save()
        preloadNext()
        startWatchdog()
    }

    /// Clears everything that describes one track rather than the queue.
    private func resetTrackState() {
        hasStartedCurrent = false
        pausedByKid = false
        playbackTime = 0
        furthest = 0
        stalledFor = 0
        playedSeconds = 0
        loadedEntry = nil
        resumeFrom = nil
    }

    /// Starts fetching the track after this one.
    ///
    /// **As soon as the current track starts, not near its end.** Waiting until
    /// the last few seconds would close the gap for a song played through and do
    /// nothing at all for a skip — and a skip is the transition a kid actually
    /// sits through, because they are waiting for it on purpose. It also has to
    /// cover the lock screen's next-track button, which arrives at a moment
    /// nothing can predict.
    ///
    /// Detached and never awaited: this runs while music is playing and must not
    /// be able to delay it. Nothing is done with the result — the fetched song
    /// waits inside the player and is picked up by name, or is quietly dropped
    /// if the kid goes somewhere else.
    private func preloadNext() {
        guard queue.indices.contains(index + 1) else { return }
        let next = queue[index + 1].item
        Task { await session.preload(next) }
    }

    /// Drops the playhead where it was left, once and only once.
    ///
    /// Whether there is anything worth restoring was settled by ``restore()``,
    /// so this only has to place it. Clamped to the track's length all the same:
    /// the value came off disk, and seeking past the end of a song is how a
    /// resume turns into a skip.
    private func resumeIfRestored() async {
        guard let target = resumeFrom else { return }
        resumeFrom = nil

        let safe = min(target, duration.map { $0 - 1 } ?? target)
        guard safe > 0 else { return }
        await session.player.seek(to: safe)
        playbackTime = safe
        furthest = safe
        playedSeconds = safe
    }

    private func syncStatus(after interval: TimeInterval = 0) {
        let previous = playbackTime
        status = session.player.status
        playbackTime = session.player.playbackTime
        if status == .playing { hasStartedCurrent = true }

        // The two facts the end-of-track test is actually built on. Both are
        // about the playhead, because the playhead is something the player
        // reports rather than something we map — see ``hasEnded``.
        furthest = max(furthest, playbackTime)
        stalledFor = abs(playbackTime - previous) < 0.05 ? stalledFor + interval : 0

        // Latch, never re-latch: once we know which entry this track is, a
        // change in it is the thing being watched for.
        if loadedEntry == nil { loadedEntry = session.player.currentEntryID }
    }

    /// Whether MusicKit has moved off the entry we asked it to play.
    ///
    /// `nil` once the single-song queue is exhausted, and different if something
    /// replaced it. Both mean the same thing here and neither is reachable
    /// before the track has been heard playing, which is what keeps the moment
    /// between `play()` returning and the entry appearing from reading as a
    /// departure.
    private var hasLeftLoadedEntry: Bool {
        guard hasStartedCurrent, let loadedEntry else { return false }
        return session.player.currentEntryID != loadedEntry
    }

    /// Whether the track that was playing has finished.
    ///
    /// **This asks the playhead, not the status.** The first version of this
    /// asked whether the player had gone to `stopped`, on the reasoning that a
    /// one-song queue running out is a stop; it was wrong on a device, and the
    /// symptom was an album that played its first track and then sat there. The
    /// second version added `paused` with the playhead at the end, and that was
    /// wrong too. The lesson is not that a third guess at the enum is needed:
    /// `MusicKitPlayer.status` maps five of MusicKit's states onto four of ours
    /// and folds anything unrecognised into `playing`, so no reading of it is a
    /// fact. ``MusicKitPlayer/rawStatus`` exists to see the real one, and the
    /// trace in ``startWatchdog()`` prints it.
    ///
    /// What *is* a fact is where the playhead has been. So the test is: the kid
    /// heard this track through to its end, and the playhead has since stopped
    /// moving. That is true whichever of the three things the player does when a
    /// queue runs out — park at the end, wind back to zero, or claim to still be
    /// playing a track that is over — and it stays false for all three ways
    /// playback pauses in the middle.
    ///
    /// ``furthest`` is what makes the difference, and it is why this is not
    /// simply "not playing any more". Headphones pulled out mid-song pauses the
    /// player, and a rule that read a pause as an ending would answer that by
    /// skipping to the next track. Mid-song, ``furthest`` is mid-song, so it is
    /// a pause. That is also why `interrupted` — a phone call — needs no case of
    /// its own here.
    private var hasEnded: Bool {
        // The strongest test, and the only one that does not depend on the kid
        // having heard the track through: the player is no longer on the entry
        // we gave it. It is also the only one that catches the **lock screen's
        // next-track button**, which reaches `ApplicationMusicPlayer` directly,
        // runs the one-song queue out and never tells the app — leaving the
        // song killed and nothing following it. Deliberately outside the
        // `pausedByKid` guard below: a kid who paused and then pressed next on
        // the lock screen has still asked for the next song.
        if hasLeftLoadedEntry { return true }

        guard hasStartedCurrent, !pausedByKid else { return false }

        // Stopped still counts on its own. It is unambiguous when it happens,
        // and it is the one reading that does not need a length to interpret.
        if status == .stopped { return true }

        guard let duration else {
            // No length to have reached the end of. All that is left is an
            // unexplained pause that has lasted two seconds, which is a worse
            // signal — it cannot tell a finished track from an unplugged pair of
            // headphones. It is here because the alternative for a song the
            // catalog gave no length for is a queue that stops dead, and every
            // path that builds a `CatalogItem` does supply one, so this is the
            // corner rather than the case.
            return status == .paused && stalledFor >= 2
        }

        // Within a poll of the end, so the last sample before the player
        // switched entries counts as having got there.
        if furthest >= duration - 1.5 {
            return status != .playing || stalledFor >= 1
        }

        // The backstop, and the reason it is last: it fires only when the
        // playhead never got near the end, which on a working player means the
        // track really is still going. Five seconds past the catalog's length,
        // having spent that long being told we were playing, means the playhead
        // is the thing that is wrong rather than the song being long.
        return playedSeconds >= duration + 5
    }

    /// How often the player is asked what it is doing.
    ///
    /// **Tighter near the end of a track**, because that interval is dead air:
    /// whatever it is, half of it on average is added to the silence between two
    /// songs. A tenth of a second for the last few seconds of a song costs
    /// nothing measurable and takes the poll out of the gap; half a second the
    /// rest of the time is plenty for a button to look right.
    private var pollInterval: TimeInterval {
        guard let duration, playbackTime >= duration - 5 else { return 0.5 }
        return 0.1
    }

    /// Advances when a track ends on its own, and keeps ``status`` current.
    ///
    /// A poll rather than a callback: `ApplicationMusicPlayer` exposes its state
    /// as an `ObservableObject`, which is awkward to bridge under strict
    /// concurrency.
    ///
    /// `stopped` only means "ended" once the track has been observed playing.
    /// Before that it means "not started yet", and treating the two the same
    /// skips every track the instant it is tapped.
    ///
    /// It is also where the playhead gets written down while nothing else is
    /// happening. Every fifteen seconds rather than every poll: the point is to
    /// survive a crash or a flat battery, and the ordinary way out of the app
    /// already saves through ``flush()``.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var sinceSave: TimeInterval = 0
            while !Task.isCancelled {
                // Read before sleeping, so the interval that is measured is the
                // one that was actually waited.
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.current != nil else { return }

                self.syncStatus(after: interval)
                if self.status == .playing { self.playedSeconds += interval }
                self.trace()

                // The player having moved off our entry means one of two things,
                // and they are not interchangeable. If we put something behind
                // it and the player is now on an entry, that is the handover we
                // arranged and the next song is already sounding. If not, the
                // queue ran out — the track ended, or the lock screen's next
                // button emptied it — and there is nothing playing to adopt.
                if self.hasLeftLoadedEntry {
                    if self.enqueued != nil, self.session.player.currentEntryID != nil {
                        await self.adoptHandover()
                    } else {
                        // The queue ran out with something still recorded as
                        // queued behind it — the lock screen emptied it, or the
                        // insert never took. Forget it before skipping, or the
                        // fast path in `skip()` will try to advance to an entry
                        // that is not there.
                        self.session.cancelNext()
                        self.enqueued = nil
                        await self.skip()
                    }
                    return
                }

                if self.hasEnded {
                    await self.skip()
                    return
                }

                // The verdict on the queued song, taken again, every poll — and
                // before the next one is offered up, so a policy edit is never
                // one tick behind the queue.
                self.pollQueuedItem()
                await self.enqueueNextIfDue()

                guard self.status == .playing else { continue }
                sinceSave += interval
                if sinceSave >= 15 {
                    sinceSave = 0
                    self.save()
                }
            }
        }
    }

    /// Prints what the player is really doing, near the end of a track and
    /// whenever it is not playing.
    ///
    /// Debug builds only, and quiet by design: the middle of a track says
    /// nothing worth reading, and a line every half second all the way through
    /// an album is a log nobody looks at. The window it does cover is the one
    /// that has now been guessed wrong twice — what `ApplicationMusicPlayer`
    /// reports as a one-song queue runs out.
    ///
    /// It answers research-question-shaped things that only a device can answer:
    /// which `playbackStatus` the end of a queue produces, whether the playhead
    /// parks at the duration or winds back, and whether the catalog's length and
    /// the player's agree. Take it out once those are written down.
    private func trace() {
        #if DEBUG
            // Three windows: the end of a track, anything that is not playing,
            // and a playhead that has sat still for two seconds while claiming
            // to play — which is what a `playbackTime` that does not work at all
            // looks like, and would otherwise print nothing.
            let nearEnd = duration.map { playbackTime >= $0 - 3 } ?? false
            guard nearEnd || status != .playing || stalledFor >= 2 || hasLeftLoadedEntry else {
                return
            }
            let length = duration.map { String(format: "%.1f", $0) } ?? "nil"
            print(
                """
                [queue] \(current?.item.title ?? "—") \
                status=\(status) raw=\(session.player.rawStatus) \
                time=\(String(format: "%.1f", playbackTime)) \
                furthest=\(String(format: "%.1f", furthest)) of \(length) \
                stalled=\(String(format: "%.1f", stalledFor))s \
                played=\(String(format: "%.1f", playedSeconds))s \
                started=\(hasStartedCurrent) ended=\(hasEnded)
                """
            )
        #endif
    }
}
