import Foundation

/// Whether the Apple Music library on this device is the kid's own.
///
/// **Device-local, and deliberately not in the CloudKit zone.** It describes a
/// device and the library signed in on it, not the family. A second device has
/// its own answer, and syncing this would hand it one that is false there.
public struct DeviceLibraryState: Codable, Sendable, Hashable {
    /// Not "do several people use this iPad" but *"is the Apple Music library on
    /// this device this kid's own?"* Those come apart in the case the narrower
    /// wording misses: a hand-me-down phone only the kid uses, still signed in to
    /// a parent's Apple Account.
    ///
    /// **Defaults false** — both providers live, which is the case most families
    /// are in and the one the feature exists for. That default is safe because
    /// of *when* the question is asked, not which way it points: onboarding puts
    /// it before the Apple provider's first read, so this governs only the path
    /// where the question was somehow never answered.
    public var isSharedDevice: Bool

    /// Whether onboarding has actually put the question.
    ///
    /// The invariant this exists for: **the Apple provider's first read is not
    /// issued until onboarding has asked.** The default decides what happens if
    /// the question is never answered; it must not decide what happens before it
    /// is put, because the first read is the one moment this feature can go
    /// badly wrong — the same pass that adopts a kid's own library would pull an
    /// adult library onto a child's shelf.
    ///
    /// Enforced in ``MergedLibrary``, so no future call site has to remember it.
    public var hasBeenAsked: Bool

    public init(isSharedDevice: Bool = false, hasBeenAsked: Bool = false) {
        self.isSharedDevice = isSharedDevice
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
    /// asked, which is the honest reading anyway.
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
