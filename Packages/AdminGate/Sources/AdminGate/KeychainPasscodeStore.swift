import Foundation
import Security

/// The admin passcode, in the Keychain.
///
/// **Deliberately not in the app's own store.** The passcode has to survive a
/// reinstall: a kid who works out that deleting and reinstalling the app clears
/// the gate has beaten it, and nothing else in the design would stop them.
/// SwiftData does not survive that. The Keychain does.
///
/// Accessibility is `AfterFirstUnlockThisDeviceOnly`: readable in the
/// background once the device has been unlocked since boot, and never synced to
/// another device or restored onto one. A family's second parent gets their own
/// passcode rather than inheriting this one.
public struct KeychainPasscodeStore: PasscodeStore {
    public enum Failure: Error, Equatable {
        /// The Keychain refused, carrying its own status code — which is the
        /// only useful thing to report, since the causes are all environmental.
        case keychain(OSStatus)

        /// Stored bytes that are not a record. Treated as no passcode set,
        /// never as a passcode that matches nothing.
        case corrupt
    }

    private let service: String
    private let account: String
    private let saltByteCount = 16

    public init(
        service: String = "com.thegoldenmule.auralsanbox.admin",
        account: String = "admin-passcode"
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

    public func record() throws -> PasscodeRecord? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Failure.corrupt }
            return try decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    public func save(_ record: PasscodeRecord) throws {
        let data = encode(record)

        // Update first, then add. Add-then-handle-duplicate would leave the old
        // passcode in place on the duplicate path, which is the one case where
        // failing quietly means the gate still opens to the previous code.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw Failure.keychain(updateStatus) }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.keychain(addStatus) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    // MARK: - Bytes
    //
    // salt ‖ hash, fixed widths, no container format. There is exactly one
    // producer and one consumer, and a plist or JSON here would be a schema to
    // migrate for no benefit.

    private func encode(_ record: PasscodeRecord) -> Data {
        record.salt + record.hash
    }

    private func decode(_ data: Data) throws -> PasscodeRecord {
        guard data.count > saltByteCount else { throw Failure.corrupt }
        return PasscodeRecord(
            salt: data.prefix(saltByteCount),
            hash: data.dropFirst(saltByteCount)
        )
    }
}
