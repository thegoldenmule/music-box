import Foundation

/// Device-local, unsynced: who's present, a claim only — grants nothing.
public protocol ActingGrownUpStore: Sendable {
    var actingGrownUpID: UUID? { get }
    func save(_ id: UUID?)
}

/// The real one. `UserDefaults` because it is per-device and never synced.
public struct UserDefaultsActingGrownUp: ActingGrownUpStore {
    /// Namespaced so it reads as ours in a defaults dump.
    public static let key = "com.thegoldenmule.auralsandbox.actingGrownUp"

    /// Thread-safe by Apple's docs; `nonisolated(unsafe)` only predates `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Absent and unreadable both read as nobody, the state before anyone was named.
    public var actingGrownUpID: UUID? {
        guard let raw = defaults.string(forKey: Self.key) else { return nil }
        return UUID(uuidString: raw)
    }

    public func save(_ id: UUID?) {
        guard let id else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(id.uuidString, forKey: Self.key)
    }
}

/// For tests, and for a preview that should not touch a real defaults domain.
public final class InMemoryActingGrownUp: ActingGrownUpStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UUID?

    public init(_ id: UUID? = nil) {
        stored = id
    }

    public var actingGrownUpID: UUID? {
        lock.withLock { stored }
    }

    public func save(_ id: UUID?) {
        lock.withLock { stored = id }
    }
}
