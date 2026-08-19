import Foundation

/// Whether the library here is the kid's own; device-local, never synced.
public struct DeviceLibraryState: Codable, Sendable, Hashable {
    /// *"Are you sharing this device with your child?"*
    public var sharesDeviceWithChild: Bool

    /// "Does your child have an Apple Music account of their own?"
    public var childHasOwnAccount: Bool

    /// Whether anyone's been asked — the Apple provider's first read waits.
    public var hasBeenAsked: Bool

    /// The kid's own only if both are true; otherwise nothing is read from it.
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

/// Where the answer is kept — a seam, so it never reaches the CloudKit zone.
public protocol DeviceLibraryStateStore: Sendable {
    var state: DeviceLibraryState { get }
    func save(_ state: DeviceLibraryState)
}

/// The real one; `UserDefaults`, because it's per-device and never synced.
public struct UserDefaultsDeviceLibraryState: DeviceLibraryStateStore {
    /// Namespaced so it reads as ours in a defaults dump.
    public static let key = "com.thegoldenmule.auralsandbox.deviceLibraryState"

    /// `UserDefaults` is thread-safe; `Sendable` just predates the annotation.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An unreadable value reads as unasked — never a throw, just one re-ask.
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
