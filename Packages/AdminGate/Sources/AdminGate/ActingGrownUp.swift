import Foundation

/// Which grown-up is behind the gate on this device.
///
/// **Device-local, and deliberately not in the CloudKit zone.** The roster of
/// adults is a fact about the household and syncs; *which of them is holding this
/// phone* is a fact about the phone. Syncing it would mean one parent opening
/// admin and finding themselves signed in as the other.
///
/// It sits in `AdminGate` rather than beside the roster because it is the second
/// half of what the gate answers. The passcode says an adult is present; this
/// says which one — and only for the purpose of writing their name onto what they
/// curate. It grants nothing. There is still exactly one passcode, and every
/// grown-up on the roster opens it, so this is what somebody *claims* rather than
/// what they proved. That is the right standing for a name on a shelf and the
/// wrong one for anything else; nothing else should read it.
///
/// Stores the identifier alone. Holding the name here too would be a second copy
/// of a synced value, free to drift from the roster and with no rule saying which
/// one wins.
public protocol ActingGrownUpStore: Sendable {
    var actingGrownUpID: UUID? { get }
    func save(_ id: UUID?)
}

/// The real one. `UserDefaults` because it is per-device and never synced.
public struct UserDefaultsActingGrownUp: ActingGrownUpStore {
    /// Namespaced so it reads as ours in a defaults dump.
    public static let key = "com.thegoldenmule.auralsandbox.actingGrownUp"

    /// `UserDefaults` is documented thread-safe and is not `Sendable` only
    /// because it predates the annotation.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An absent or unreadable value is nobody, which is the same state a device
    /// is in before anyone has been named. Nothing to fail over: a write then
    /// stamps `nil` and the shelf reads as it did before the roster existed.
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
