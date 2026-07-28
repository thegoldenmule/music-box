import CatalogKit
import FamilyStore
import Foundation

/// What a kid was playing, written down so it is still there next launch.
///
/// **Device-local, and deliberately not in the CloudKit zone** — the same call
/// ``DeviceLibraryState`` makes and for a stronger reason. A queue describes one
/// device's speaker: syncing it would have a kid's iPad resume mid-album because
/// somebody pressed play on the Mac, and a second device would fight the first
/// over whose turn it is. It is also disposable, which the family's records are
/// not; the whole cost of a queue that fails to decode is an app that opens with
/// nothing loaded.
///
/// That disposability is what makes the encoded shape free to change. Nothing
/// here is a schema decision in the sense the rest of the store's fields are.
///
/// **Not a permission, and not a policy input.** Every entry is judged again
/// before it plays, exactly as if the kid had just tapped it — see
/// `KidPlayerModel`. A queue restored from disk has aged past whatever verdict
/// put it there, so what it holds is a list of things to *ask* about.
public struct PlayQueue: Codable, Sendable, Hashable {
    /// One song, and where the kid got to it from.
    ///
    /// The origin travels with the song rather than sitting on the queue,
    /// because it is what the report reads and it has to survive being written
    /// down: a track resumed the next morning was still played from the album
    /// the kid opened yesterday, and a queue that forgot that would file the
    /// whole session under nothing.
    public struct Entry: Codable, Sendable, Hashable {
        public let item: CatalogItem
        public let origin: PlaybackOrigin

        public init(item: CatalogItem, origin: PlaybackOrigin) {
            self.item = item
            self.origin = origin
        }
    }

    /// How many entries are kept.
    ///
    /// A queue is an album or a page of results, so this bites approximately
    /// never — it is here because the size of what a screen hands the player is
    /// not this type's decision, and an unbounded value in `UserDefaults` is
    /// read back into memory at every launch.
    public static let maxEntries = 100

    public var entries: [Entry]

    /// Which entry is loaded. Always a valid index into ``entries`` for a queue
    /// that came out of ``trimmed()``.
    public var index: Int

    /// How far into the current song the kid had got.
    ///
    /// Kept so coming back lands where they left rather than at the top of the
    /// track. It is a hint and not a promise: the player only uses it when the
    /// catalog gives the song a length to check it against.
    public var elapsed: TimeInterval

    public init(entries: [Entry], index: Int = 0, elapsed: TimeInterval = 0) {
        self.entries = entries
        self.index = index
        self.elapsed = elapsed
    }

    public var isEmpty: Bool { current == nil }

    public var current: Entry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    /// The form that goes to disk.
    ///
    /// **Everything already played is dropped**, which is not a size
    /// optimisation dressed up as a rule: there is no previous control anywhere
    /// in the kid's app, so nothing behind the playhead is reachable and keeping
    /// it would be storing a listening history under a different name. What is
    /// left is the song that was loaded and what was going to follow it, which
    /// is the whole of what "resume" means here.
    ///
    /// An index that points nowhere yields an empty queue rather than a clamped
    /// one. Guessing which song a broken index meant is how a kid comes back to
    /// a track they never played.
    public func trimmed() -> PlayQueue {
        guard entries.indices.contains(index) else { return PlayQueue(entries: []) }
        let remaining = Array(entries[index...].prefix(Self.maxEntries))
        return PlayQueue(entries: remaining, index: 0, elapsed: elapsed)
    }
}

/// Where the queue is kept.
///
/// A protocol for the reason ``DeviceLibraryStateStore`` is one: this must never
/// reach the CloudKit zone, and a seam makes that a property of the type rather
/// than something every call site has to remember. Every implementation is
/// device-local by construction.
///
/// Keyed by kid, because the queue is one child's. A parent switching to another
/// child in the admin finds that child's own queue, not the one that was
/// playing — see `KidPlayerModel.switchedKid()`.
public protocol PlayQueueStore: Sendable {
    /// What this kid was playing, or `nil` if there is nothing to come back to.
    func queue(for kid: UUID) -> PlayQueue?

    /// Writes the queue, trimming it first. Saving an empty queue clears the
    /// slot rather than storing an empty one — the two mean the same thing to a
    /// reader and only one of them leaves a row behind.
    func save(_ queue: PlayQueue, for kid: UUID)

    /// Forgets this kid's queue. What a history wipe calls.
    func clear(for kid: UUID)
}

/// The real one. `UserDefaults` because it is per-device and never synced.
public struct UserDefaultsPlayQueueStore: PlayQueueStore {
    /// Namespaced so it reads as ours in a defaults dump, and suffixed per kid
    /// so clearing one child's queue cannot disturb another's — which a single
    /// dictionary under one key would have made a read-modify-write.
    public static let keyPrefix = "com.thegoldenmule.auralsandbox.playQueue."

    static func key(for kid: UUID) -> String { keyPrefix + kid.uuidString }

    /// `UserDefaults` is documented thread-safe and is not `Sendable` only
    /// because it predates the annotation.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An unreadable or absent value is nothing to resume. Not a throw: there is
    /// nothing a caller could do about it that differs from having closed the
    /// app with nothing playing, and it is what keeps the encoded shape free to
    /// change without a migration.
    public func queue(for kid: UUID) -> PlayQueue? {
        guard
            let data = defaults.data(forKey: Self.key(for: kid)),
            let decoded = try? JSONDecoder().decode(PlayQueue.self, from: data),
            !decoded.isEmpty
        else { return nil }
        return decoded
    }

    public func save(_ queue: PlayQueue, for kid: UUID) {
        let trimmed = queue.trimmed()
        guard !trimmed.isEmpty, let data = try? JSONEncoder().encode(trimmed) else {
            clear(for: kid)
            return
        }
        defaults.set(data, forKey: Self.key(for: kid))
    }

    public func clear(for kid: UUID) {
        defaults.removeObject(forKey: Self.key(for: kid))
    }
}

/// For tests, and for a preview that should not touch a real defaults domain.
public final class InMemoryPlayQueueStore: PlayQueueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: PlayQueue] = [:]

    public init() {}

    public func queue(for kid: UUID) -> PlayQueue? {
        lock.withLock { stored[kid] }
    }

    public func save(_ queue: PlayQueue, for kid: UUID) {
        let trimmed = queue.trimmed()
        lock.withLock { stored[kid] = trimmed.isEmpty ? nil : trimmed }
    }

    public func clear(for kid: UUID) {
        lock.withLock { stored[kid] = nil }
    }
}
