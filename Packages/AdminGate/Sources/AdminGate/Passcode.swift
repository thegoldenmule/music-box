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

    /// Which household epoch this local item was written for.
    ///
    /// **Zero means "written before epochs existed"**, which is a real state with
    /// existing installs behind it, not a theoretical one — see
    /// ``KeychainPasscodeStore``. It sorts below ``PasscodeEpoch/first``, so such a
    /// device is treated as stale the moment a household epoch appears and is made
    /// to accept the current code. That is the fail-closed direction: the cost is
    /// one parent typing the code they already know, and the alternative is a
    /// device opening to a code that has since been rotated.
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

    /// Derives a record from a passcode and a caller-supplied salt.
    ///
    /// The salt is a parameter rather than generated here so tests are
    /// deterministic. ``make(_:)`` is the one that reaches for randomness.
    public static func make(_ passcode: String, salt: Data, epoch: Int = 0) -> PasscodeRecord {
        PasscodeRecord(salt: salt, hash: digest(passcode, salt: salt), epoch: epoch)
    }

    public static func make(_ passcode: String, epoch: Int = 0) -> PasscodeRecord {
        make(passcode, salt: randomSalt(), epoch: epoch)
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

/// Whether this device has a gate — in three states, because two is a lie.
///
/// ``PasscodeStore/record()`` can return `nil` and it can *throw*, and those are
/// not the same fact about a household. Collapsing them is what
/// `((try? record()) ?? nil) != nil` did: a Keychain that errored read exactly
/// like a device nobody had ever set a code on, and the screen that asks is the
/// one that offers to **choose** a new one. So a transient read failure on a
/// device holding a family's entire policy set and every child's search history
/// offered to replace the passcode protecting them, and would have succeeded —
/// `setPasscode` guards on this and nothing else.
///
/// Three states, and the third is the point.
public enum PasscodeAvailability: Sendable, Equatable {
    /// A passcode exists and was read.
    case configured
    /// The store answered, and there is nothing there. The only state that may
    /// offer to choose one.
    case absent
    /// The store could not be read. Says nothing about whether a passcode
    /// exists, which is precisely why it must not be treated as `absent`.
    case unreadable
}

extension PasscodeStore {
    /// The honest three-state answer. Prefer this wherever the difference can
    /// be shown to somebody.
    public var availability: PasscodeAvailability {
        do {
            return try record() == nil ? .absent : .configured
        } catch {
            return .unreadable
        }
    }

    /// The two-state answer, for callers that genuinely only need *is there a
    /// gate* — and it **fails closed**: unreadable counts as configured.
    ///
    /// The asymmetry is deliberate and matches how `unlockAdmin` already behaves
    /// on the same call. Failing closed costs an adult a confusing screen on a
    /// device whose Keychain is broken, and they can still get in with the code
    /// they know. Failing open hands the gate to whoever is holding the device,
    /// which on the kid's iPad is the child. A wrong answer in one direction is
    /// an annoyance and in the other it is the feature not existing.
    public var isConfigured: Bool {
        availability != .absent
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
