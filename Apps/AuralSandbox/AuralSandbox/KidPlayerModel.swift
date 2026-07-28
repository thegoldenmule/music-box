import CatalogKit
import FamilyStore
import Foundation
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

    init(session: Session) {
        self.session = session
    }

    // MARK: - Starting

    /// Plays one item, with the rest of its surface behind it.
    ///
    /// `queue` is already filtered — blocked items never enter it. That is not
    /// a substitute for the re-check, it is in addition to one: the list was
    /// filtered when the screen drew, and a parent may have denied something in
    /// the meantime.
    func play(_ item: CatalogItem, from queue: [CatalogItem], origin: PlaybackOrigin) async {
        let entries = queue.map { Entry(item: $0, origin: origin) }
        self.queue = entries.isEmpty ? [Entry(item: item, origin: origin)] : entries
        index = self.queue.firstIndex { $0.item.id == item.id } ?? 0
        await playCurrent()
    }

    // MARK: - Controls
    //
    // Play, pause, skip. That is the entire surface: no stop, no scrubber, no
    // shuffle, no repeat, no station. The absence of a stop is why a play has
    // to be flushed from several places — see `Session.flushCurrentPlay`.

    func togglePlayPause() async {
        guard current != nil else { return }
        do {
            if isPlaying {
                try await session.player.pause()
            } else if status == .paused {
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
    func seek(to seconds: TimeInterval) async {
        guard current != nil else { return }
        let target = min(max(0, seconds), duration ?? seconds)
        await session.player.seek(to: target)
        playbackTime = target
    }

    /// Skip forward. Stops at the end rather than wandering into anything.
    func skip() async {
        guard !queue.isEmpty else { return }
        session.flushCurrentPlay()
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
    }

    /// Writes the play in progress without disturbing playback.
    ///
    /// Called when the app goes to the background. With no stop control, a kid
    /// who plays one song and puts the phone down would otherwise never produce
    /// a play event at all — which is exactly why recents stayed empty.
    func flush() {
        session.flushCurrentPlay()
    }

    // MARK: - The re-check

    /// Plays whatever `index` points at, asking the engine again first.
    private func playCurrent() async {
        guard let entry = current else { return }

        isBusy = true
        defer { isBusy = false }
        hasStartedCurrent = false
        playbackTime = 0

        do {
            try await session.play(entry.item, origin: entry.origin)
            message = nil
            syncStatus()
            startWatchdog()
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
        }
    }

    private func syncStatus() {
        status = session.player.status
        playbackTime = session.player.playbackTime
        if status == .playing { hasStartedCurrent = true }
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
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.current != nil else { return }

                self.syncStatus()

                if self.hasStartedCurrent, self.status == .stopped {
                    await self.skip()
                    return
                }
            }
        }
    }
}
