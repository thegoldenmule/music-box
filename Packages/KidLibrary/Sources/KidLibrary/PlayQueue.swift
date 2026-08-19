import CatalogKit
import FamilyStore
import Foundation

/// Not a permission: every queued entry is judged again, fresh, before it plays.
public struct PlayQueue: Codable, Sendable, Hashable {
    /// A song and its origin, paired so a resumed track still reports correctly.
    public struct Entry: Codable, Sendable, Hashable {
        public let item: CatalogItem
        public let origin: PlaybackOrigin

        public init(item: CatalogItem, origin: PlaybackOrigin) {
            self.item = item
            self.origin = origin
        }
    }

    /// Cap on entries, so a page of results can't grow UserDefaults unbounded.
    public static let maxEntries = 100

    public var entries: [Entry]

    /// Which entry is loaded; always valid for a queue that came from `trimmed()`.
    public var index: Int

    /// Seconds into the song; a hint, used only if the catalog confirms length.
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

    /// On-disk form: already-played entries drop — nothing behind is reachable.
    public func trimmed() -> PlayQueue {
        guard entries.indices.contains(index) else { return PlayQueue(entries: []) }
        let remaining = Array(entries[index...].prefix(Self.maxEntries))
        return PlayQueue(entries: remaining, index: 0, elapsed: elapsed)
    }
}

/// Where the queue lives — device-local, keyed per kid so switching can't leak.
public protocol PlayQueueStore: Sendable {
    /// What this kid was playing, or `nil` if there is nothing to come back to.
    func queue(for kid: UUID) -> PlayQueue?

    /// Writes the queue, trimmed; an empty queue clears the slot, not stores one.
    func save(_ queue: PlayQueue, for kid: UUID)

    /// Forgets this kid's queue. What a history wipe calls.
    func clear(for kid: UUID)
}

/// The real one. `UserDefaults` because it is per-device and never synced.
public struct UserDefaultsPlayQueueStore: PlayQueueStore {
    /// Namespaced, suffixed per kid — clearing one queue can't touch another's.
    public static let keyPrefix = "com.thegoldenmule.auralsandbox.playQueue."

    static func key(for kid: UUID) -> String { keyPrefix + kid.uuidString }

    /// `UserDefaults` is thread-safe; `Sendable` just predates the annotation.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An unreadable or absent value just means nothing to resume — never a throw.
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
