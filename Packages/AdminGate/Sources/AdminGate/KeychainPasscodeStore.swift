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
    // salt ‖ hash ‖ epoch, fixed widths, no container format. There is exactly one
    // producer and one consumer, and a plist or JSON here would be a schema to
    // migrate for no benefit.
    //
    // **The epoch is appended, and its absence is the migration.** Items written
    // before epochs existed are salt ‖ hash and nothing else, and there are real
    // installs holding one. A shorter blob reads back at epoch 0, which sorts below
    // `PasscodeEpoch.first` and therefore reads as stale rather than as current —
    // the fail-closed direction. Length is the discriminator rather than a version
    // byte because adding a version byte to a format with no version byte has the
    // same problem one level up.

    // Reachable from tests because the length discrimination below is the part with
    // a real failure behind it, and it cannot be exercised through the Keychain —
    // that needs a device and an entitlement, which is the whole reason
    // `PasscodeStore` is a protocol.
    func encodeForTests(_ record: PasscodeRecord) -> Data { encode(record) }
    func decodeForTests(_ data: Data) throws -> PasscodeRecord { try decode(data) }

    private let hashByteCount = 32
    private let epochByteCount = 4

    private var legacyLength: Int { saltByteCount + hashByteCount }
    private var currentLength: Int { legacyLength + epochByteCount }

    private func encode(_ record: PasscodeRecord) -> Data {
        var data = Data(record.salt) + Data(record.hash)
        var epoch = UInt32(clamping: record.epoch).bigEndian
        withUnsafeBytes(of: &epoch) { data.append(contentsOf: $0) }
        return data
    }

    /// **Discriminated on exact length, not on "is there more".** The first attempt
    /// at this asked whether anything followed the salt by more than four bytes,
    /// which is true of a 48-byte pre-epoch item — so it read the last four bytes of
    /// the *hash* as an epoch and every existing install would have stopped
    /// recognising its own passcode. Both widths are fixed, which is exactly what
    /// makes the length a safe discriminator, and it is the reason this format has
    /// no version byte to begin with.
    private func decode(_ data: Data) throws -> PasscodeRecord {
        switch data.count {
        case legacyLength:
            return PasscodeRecord(
                salt: Data(data.prefix(saltByteCount)),
                hash: Data(data.dropFirst(saltByteCount)),
                epoch: 0
            )
        case currentLength:
            let body = data.dropLast(epochByteCount)
            let epoch = data.suffix(epochByteCount).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return PasscodeRecord(
                salt: Data(body.prefix(saltByteCount)),
                hash: Data(body.dropFirst(saltByteCount)),
                epoch: Int(epoch)
            )
        default:
            throw Failure.corrupt
        }
    }
}
