import CatalogKit
import FamilyStore
import Foundation
import SwiftUI

/// The kid's queue and what is playing.
///
/// **The queue lives here, not in MusicKit.** `MusicKitPlayer` is handed one
/// song at a time on purpose: if the whole album went into `ApplicationMusicPlayer`
/// it would advance by itself, and every advance past the first track would
/// happen without the policy engine being asked. Holding the queue here means
/// every track is judged immediately before it plays, including the ones nobody
/// tapped.
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

    /// The one message a kid may ever see about a block, and only for a track
    /// filtered out of something they were already allowed to play.
    private(set) var message: String?

    var current: Entry? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var isPlaying: Bool { session.player.status == .playing }

    private let session: Session
    private var watchdog: Task<Void, Never>?

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
    // Play, pause, skip. That is the entire surface, and there is no next
    // beyond the queue, no shuffle, no repeat, and no station.

    func togglePlayPause() async {
        guard current != nil else { return }
        do {
            if isPlaying {
                try await session.player.pause()
            } else if session.player.status == .paused {
                try await session.resume()
            } else {
                await playCurrent()
            }
        } catch {
            message = Session.message(for: error)
        }
    }

    /// Skip forward. Stops at the end rather than wandering into anything.
    func skip() async {
        guard !queue.isEmpty else { return }
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
    }

    // MARK: - The re-check

    /// Plays whatever `index` points at, asking the engine again first.
    ///
    /// A blocked entry is skipped rather than surfaced — except when it came
    /// from a playlist, where the kid was already promised the playlist and a
    /// silent gap would read as a fault. That is the only block a kid ever
    /// sees, and it never names the rule.
    private func playCurrent() async {
        guard let entry = current else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            try await session.play(entry.item, origin: entry.origin)
            message = nil
            startWatchdog()
        } catch is Session.Refused {
            // Already logged by Session.play, with its reason.
            if case .playlist = entry.origin {
                message = "Skipping this one — let's try the next."
            }
            await skip()
        } catch {
            // A track that will not load is skipped too, for the same reason a
            // blocked one is: stopping dead on it strands the kid.
            await skip()
        }
    }

    /// Advances when a track ends on its own.
    ///
    /// A poll rather than a callback: `ApplicationMusicPlayer` exposes its state
    /// as an `ObservableObject`, which is awkward to bridge under strict
    /// concurrency, and a second of latency at the end of a song is not
    /// something a listener can hear. `stopped` while something is loaded means
    /// the track finished; `paused` and `interrupted` leave the queue alone.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.current != nil else { return }
                if self.session.player.status == .stopped {
                    await self.skip()
                    return
                }
            }
        }
    }
}
