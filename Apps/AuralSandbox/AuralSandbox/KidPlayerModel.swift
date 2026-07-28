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

    /// Where the current track was up to when the app last closed.
    ///
    /// Consumed by the first play after a restore and cleared by anything that
    /// changes which song is loaded — it belongs to one entry, and carrying it
    /// to the next would drop a kid thirty seconds into a track they have not
    /// heard.
    private var resumeFrom: TimeInterval?

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
            message = Session.message(for: error)
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
    }

    /// Skip forward. Stops at the end rather than wandering into anything.
    func skip() async {
        guard !queue.isEmpty else { return }
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
        await session.stop()
        queue = []
        index = 0
        status = .stopped
        playbackTime = 0
        resumeFrom = nil
        pausedByKid = false
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
        await session.stop()
        owner = session.kid.id
        queue = []
        index = 0
        status = .stopped
        playbackTime = 0
        message = nil
        hasStartedCurrent = false
        pausedByKid = false
        resumeFrom = nil
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
        hasStartedCurrent = false
        pausedByKid = false
        playbackTime = 0

        do {
            try await session.play(entry.item, origin: entry.origin)
            message = nil
            syncStatus()
            await resumeIfRestored()
            startWatchdog()
            save()
        } catch is Session.Refused {
            // Already logged by Session.play, with its reason. Skipped rather
            // than surfaced, except from a playlist where the kid was already
            // promised the playlist and a silent gap reads as a fault. Their own
            // playlist counts double: they put the song there themselves.
            switch entry.origin {
            case .playlist, .kidPlaylist:
                message = "Skipping this one — let's try the next."
            case .home, .search, .browse:
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
            message = Session.message(for: error)
            status = .stopped
            // Still written down: the queue is intact and the kid can press play
            // again, now or after relaunching, and the failure was the network's
            // rather than this entry's.
            save()
        }
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
    }

    private func syncStatus() {
        status = session.player.status
        playbackTime = session.player.playbackTime
        if status == .playing { hasStartedCurrent = true }
    }

    /// Whether the track that was playing has finished.
    ///
    /// **Two tests, because one of them is unverified.** `stopped` is what a
    /// finished one-song queue is expected to report, and it is the reading this
    /// file was written against — but nothing Apple-facing has run yet, and
    /// `ApplicationMusicPlayer` reporting `paused` at the end of its queue
    /// instead would show up as an app that plays the first track of an album
    /// and then sits there. So a player that has stopped short of nowhere near
    /// the end counts, and so does one that is not playing with the playhead at
    /// the end of a track whose length the catalog gave us.
    ///
    /// Both are gated on the kid not having done it themselves. A child holding
    /// the app paused on the last seconds of a song must not have it advance out
    /// from under them, and `interrupted` — a phone call — is not an ending
    /// either: it reports its own state and never satisfies the second test's
    /// `paused`.
    ///
    /// Delete the second test once the first is confirmed on a device, and keep
    /// the second if the first turns out never to fire.
    private var hasEnded: Bool {
        guard hasStartedCurrent, !pausedByKid else { return false }
        if status == .stopped { return true }
        guard status == .paused, let duration else { return false }
        return playbackTime >= duration - 1
    }

    /// Advances when a track ends on its own, and keeps ``status`` current.
    ///
    /// A poll rather than a callback: `ApplicationMusicPlayer` exposes its state
    /// as an `ObservableObject`, which is awkward to bridge under strict
    /// concurrency. Half a second is fast enough for a button to look right and
    /// slow enough to cost nothing.
    ///
    /// `stopped` only means "ended" once the track has been observed playing.
    /// Before that it means "not started yet", and treating the two the same
    /// skips every track the instant it is tapped.
    ///
    /// It is also where the playhead gets written down while nothing else is
    /// happening. Every fifteen seconds rather than every tick: the point is to
    /// survive a crash or a flat battery, and the ordinary way out of the app
    /// already saves through ``flush()``.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.current != nil else { return }

                self.syncStatus()

                if self.hasEnded {
                    await self.skip()
                    return
                }

                ticks += 1
                if ticks % 30 == 0, self.status == .playing { self.save() }
            }
        }
    }
}
