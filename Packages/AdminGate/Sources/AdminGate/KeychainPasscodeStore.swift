import Foundation
import Security

/// Keychain, not SwiftData: must survive a reinstall, or that clears the gate.
public struct KeychainPasscodeStore: PasscodeStore {
    public enum Failure: Error, Equatable {
        /// The status code is the only useful thing to report — causes are environmental.
        case keychain(OSStatus)

        /// Unparseable bytes read as no passcode set, never as one that matches nothing.
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

        // Try update first — adding to a duplicate key would leave the old code active.
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
    // salt‖hash‖epoch: pre-epoch items decode at epoch 0, failing closed as stale.

    // Exposed to tests: decode's length switch needs no device, unlike the Keychain.
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

    /// Exact-length match, not "more follows the salt" — that misread hash as epoch.
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
