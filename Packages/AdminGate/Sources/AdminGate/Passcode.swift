import CryptoKit
import Foundation

/// Salted hash, never the raw code — a dump shouldn't leak a reused code.
public struct PasscodeRecord: Sendable, Equatable {
    public let salt: Data
    public let hash: Data

    /// Zero means pre-epoch, a real state on old installs — sorts stale, fail-closed.
    public let epoch: Int

    public init(salt: Data, hash: Data, epoch: Int = 0) {
        self.salt = salt
        self.hash = hash
        self.epoch = epoch
    }

    /// The same record, stamped for a household epoch.
    public func at(epoch: Int) -> PasscodeRecord {
        PasscodeRecord(salt: salt, hash: hash, epoch: epoch)
    }

    /// Salt is a parameter, not generated here, so tests are deterministic.
    public static func make(_ passcode: String, salt: Data, epoch: Int = 0) -> PasscodeRecord {
        PasscodeRecord(salt: salt, hash: digest(passcode, salt: salt), epoch: epoch)
    }

    public static func make(_ passcode: String, epoch: Int = 0) -> PasscodeRecord {
        make(passcode, salt: randomSalt(), epoch: epoch)
    }

    /// Constant-time, so timing can't leak how much of a guess was right.
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

/// So the gate is testable with no device, entitlement, or signed build.
public protocol PasscodeStore: Sendable {
    /// `nil` puts first run on the choose-a-passcode path, not enter-it.
    func record() throws -> PasscodeRecord?
    func save(_ record: PasscodeRecord) throws
    func clear() throws
}

/// Nil vs throw differ; conflating them let `setPasscode` replace a working code.
public enum PasscodeAvailability: Sendable, Equatable {
    /// A passcode exists and was read.
    case configured
    /// Answered empty — the only state allowed to offer choosing one.
    case absent
    /// Unread, not absent — the two must never be conflated.
    case unreadable
}

extension PasscodeStore {
    /// The honest three-state answer — prefer it wherever the difference is visible.
    public var availability: PasscodeAvailability {
        do {
            return try record() == nil ? .absent : .configured
        } catch {
            return .unreadable
        }
    }

    /// Fails closed like `unlockAdmin`: unreadable counts as configured, not absent.
    public var isConfigured: Bool {
        availability != .absent
    }
}

/// For tests and previews; forgets on exit, which the real store must never do.
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
