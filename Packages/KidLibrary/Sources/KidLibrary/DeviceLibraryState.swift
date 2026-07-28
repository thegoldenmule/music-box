import Foundation

/// Whether the Apple Music library on this device is the kid's own.
///
/// **Device-local, and deliberately not in the CloudKit zone.** It describes a
/// device and the library signed in on it, not the family. A second device has
/// its own answer, and syncing this would hand it one that is false there.
///
/// Two answers rather than one, because *"is this library the kid's own?"* is
/// not a question a parent can answer without first working out what it means.
/// Two facts they already know decide it between them, and the pair covers the
/// case a single question kept getting wrong — a hand-me-down phone nobody else
/// touches, still signed in to a parent's Apple Account.
public struct DeviceLibraryState: Codable, Sendable, Hashable {
    /// *"Are you sharing this device with your child?"*
    public var sharesDeviceWithChild: Bool

    /// *"Does your child have an Apple Music account of their own, through your
    /// Apple Family?"*
    public var childHasOwnAccount: Bool

    /// Whether anyone has actually been asked.
    ///
    /// The invariant this exists for: **the Apple provider's first read is not
    /// issued until onboarding has asked.** The defaults decide what happens if
    /// the questions are never answered; they must not decide what happens
    /// before they are put, because the first read is the one moment this
    /// feature can go badly wrong — the same pass that adopts a kid's own
    /// library would pull an adult library onto a child's shelf.
    ///
    /// Enforced in ``MergedLibrary``, so no future call site has to remember it.
    public var hasBeenAsked: Bool

    /// The one input to which providers are live, derived rather than stored.
    ///
    /// The library is the kid's own only when **both** are true: the device is
    /// theirs alone, and the account signed in is theirs. Either one failing
    /// means the library on this device belongs to a grown-up, and nothing is
    /// read from it or written to it.
    ///
    /// **Defaults false** — both providers live, which is the case most families
    /// are in and the one the feature exists for. That default is safe because
    /// of *when* the questions are asked, not which way they point: onboarding
    /// puts them before the Apple provider's first read, so this governs only
    /// the path where they were somehow never answered.
    public var isSharedDevice: Bool {
        sharesDeviceWithChild || !childHasOwnAccount
    }

    public init(
        sharesDeviceWithChild: Bool = false,
        childHasOwnAccount: Bool = true,
        hasBeenAsked: Bool = false
    ) {
        self.sharesDeviceWithChild = sharesDeviceWithChild
        self.childHasOwnAccount = childHasOwnAccount
        self.hasBeenAsked = hasBeenAsked
    }

    public static let unasked = DeviceLibraryState()
}

/// Where the answer is kept.
///
/// A protocol because the answer must never reach the CloudKit zone, and having
/// a seam is what makes that visible rather than a thing to remember. Every
/// implementation is device-local by construction.
public protocol DeviceLibraryStateStore: Sendable {
    var state: DeviceLibraryState { get }
    func save(_ state: DeviceLibraryState)
}

/// The real one. `UserDefaults` because it is per-device and never synced —
/// `NSUbiquitousKeyValueStore` would be the wrong shelf for exactly this value.
public struct UserDefaultsDeviceLibraryState: DeviceLibraryStateStore {
    /// Namespaced so it reads as ours in a defaults dump.
    public static let key = "com.thegoldenmule.auralsandbox.deviceLibraryState"

    /// `UserDefaults` is documented thread-safe and is not `Sendable` only
    /// because it predates the annotation.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An unreadable or absent value is the unasked default. Not a throw: there
    /// is nothing a caller could do about it that differs from never having been
    /// asked, which is the honest reading anyway — and it is what makes changing
    /// the shape of the questions cost one re-ask rather than a migration.
    public var state: DeviceLibraryState {
        guard
            let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode(DeviceLibraryState.self, from: data)
        else { return .unasked }
        return decoded
    }

    public func save(_ state: DeviceLibraryState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// For tests, and for a preview that should not touch a real defaults domain.
public final class InMemoryDeviceLibraryState: DeviceLibraryStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DeviceLibraryState

    public init(_ state: DeviceLibraryState = .unasked) {
        stored = state
    }

    public var state: DeviceLibraryState {
        lock.withLock { stored }
    }

    public func save(_ state: DeviceLibraryState) {
        lock.withLock { stored = state }
    }
}
