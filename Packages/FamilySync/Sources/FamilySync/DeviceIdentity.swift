import Foundation
import Security

/// This device's own identifier, minted once and kept.
///
/// **`DeviceRecord.id` says it is "minted by the device itself, into its own
/// Keychain, and by nothing else." This is that, and until now it did not
/// exist** — which is why nothing in the app had ever created a `DeviceRecord`.
///
/// Never `identifierForVendor`: it does not exist on native macOS, and Apple
/// documents it as changing on Xcode and ad-hoc installs and as `nil` before
/// first unlock. Each of those would silently re-enroll a device that is already
/// enrolled.
///
/// **A device that reads an empty store registers as new rather than adopting a
/// row.** The failure mode of guessing is one child's iPad inheriting another's
/// binding — the wrong sandbox level, another child's library, and every play
/// filed under the wrong name — so duplicates are left for a parent to tidy in
/// the roster. That asymmetry is the whole reason this is not derived from
/// anything.
public protocol DeviceIdentityStore: Sendable {
    /// This device's identifier, minting and storing one on first call.
    ///
    /// Throwing rather than optional: a device that cannot read its own identity
    /// must not proceed as an unenrolled one, because that path *writes a new
    /// row*. Failing loudly means a launch error; failing soft would mean a
    /// second device row every launch and a roster nobody can read.
    func identifier() throws -> UUID
}

// MARK: -

/// The real one.
///
/// Accessibility matches ``KeychainPasscodeStore``'s reasoning and lands in the
/// same place for a different reason: `AfterFirstUnlockThisDeviceOnly` because
/// this identifies *this hardware*. Syncing it would give a second device the
/// same identity as the first, which is precisely the collision the roster
/// exists to make visible.
public struct KeychainDeviceIdentity: DeviceIdentityStore {
    public enum Failure: Error, Equatable {
        case keychain(OSStatus)
        /// Stored bytes that are not a UUID. Never silently replaced — see
        /// ``identifier()``.
        case corrupt
    }

    private let service: String
    private let account: String

    public init(
        service: String = "com.thegoldenmule.auralsanbox.device",
        account: String = "device-identifier"
    ) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Reads the stored identity, or mints one.
    ///
    /// **Corrupt bytes throw rather than re-minting.** Overwriting would hand
    /// this device a new identity and orphan whatever row a parent had already
    /// bound to it — the binding silently gone, the roster holding a device that
    /// no longer exists, and the child's iPad opening as unenrolled. A hard
    /// failure is a bug report; the quiet path is a support mystery.
    public func identifier() throws -> UUID {
        if let existing = try stored() { return existing }

        let minted = UUID()
        try store(minted)
        return minted
    }

    private func stored() throws -> UUID? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 16 else { throw Failure.corrupt }
            return UUID(uuid: data.withUnsafeBytes { $0.load(as: uuid_t.self) })
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    private func store(_ id: UUID) throws {
        var query = baseQuery
        query[kSecValueData as String] = withUnsafeBytes(of: id.uuid) { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}

// MARK: -

/// For tests and previews. Mints once and keeps it, like the real one.
public final class InMemoryDeviceIdentity: DeviceIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var id: UUID?

    public init(_ id: UUID? = nil) { self.id = id }

    public func identifier() throws -> UUID {
        lock.withLock {
            if let id { return id }
            let minted = UUID()
            id = minted
            return minted
        }
    }
}

/// A store that cannot answer, for testing the path where the Keychain is
/// unreadable — which must not become "this device is new".
public struct FailingDeviceIdentity: DeviceIdentityStore {
    public init() {}
    public func identifier() throws -> UUID {
        throw KeychainDeviceIdentity.Failure.keychain(errSecInteractionNotAllowed)
    }
}
