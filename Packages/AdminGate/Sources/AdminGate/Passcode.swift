import CryptoKit
import Foundation

/// A passcode as stored: a random salt and the hash it produced.
///
/// The passcode itself is never written anywhere. The Keychain is the real
/// protection here — a four-digit code is brute-forceable in no time once you
/// have the hash — but salting and hashing means a Keychain dump does not hand
/// over a code the parent has probably reused elsewhere.
public struct PasscodeRecord: Sendable, Equatable {
    public let salt: Data
    public let hash: Data

    public init(salt: Data, hash: Data) {
        self.salt = salt
        self.hash = hash
    }

    /// Derives a record from a passcode and a caller-supplied salt.
    ///
    /// The salt is a parameter rather than generated here so tests are
    /// deterministic. ``make(_:)`` is the one that reaches for randomness.
    public static func make(_ passcode: String, salt: Data) -> PasscodeRecord {
        PasscodeRecord(salt: salt, hash: digest(passcode, salt: salt))
    }

    public static func make(_ passcode: String) -> PasscodeRecord {
        make(passcode, salt: randomSalt())
    }

    /// Constant-time comparison, so a timing difference cannot leak how much of
    /// a guess was right.
    public func matches(_ passcode: String) -> Bool {
        let candidate = Self.digest(passcode, salt: salt)
        guard candidate.count == hash.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate, hash) {
            difference |= a ^ b
        }
        return difference == 0
    }

    private static func digest(_ passcode: String, salt: Data) -> Data {
        var input = salt
        input.append(contentsOf: Array(passcode.utf8))
        return Data(SHA256.hash(data: input))
    }

    public static func randomSalt(byteCount: Int = 16) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

// MARK: - Storage

/// Where the admin passcode lives.
///
/// A protocol for the same reason the catalog has one: the gate's behaviour is
/// worth testing exhaustively, and the Keychain needs a device, an entitlement
/// and a signed build.
public protocol PasscodeStore: Sendable {
    /// `nil` when no passcode has been set — which is what puts first run into
    /// the "choose a passcode" path rather than the "enter it" one.
    func record() throws -> PasscodeRecord?
    func save(_ record: PasscodeRecord) throws
    func clear() throws
}

extension PasscodeStore {
    public var isConfigured: Bool {
        ((try? record()) ?? nil) != nil
    }
}

/// For tests and previews. Forgets everything when the process does, which is
/// exactly what the real one must not do.
public final class InMemoryPasscodeStore: PasscodeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PasscodeRecord?

    public init(_ stored: PasscodeRecord? = nil) {
        self.stored = stored
    }

    public func record() throws -> PasscodeRecord? {
        lock.withLock { stored }
    }

    public func save(_ record: PasscodeRecord) throws {
        lock.withLock { stored = record }
    }

    public func clear() throws {
        lock.withLock { stored = nil }
    }
}
