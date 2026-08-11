import CommonCrypto
import Foundation

/// The passcode as a value that can safely leave the device.
///
/// **A different work factor from ``PasscodeRecord``, for a different threat.**
/// The local record is a single salted SHA-256 and its own doc says why that is
/// enough: the Keychain is the real protection, and the hash never goes anywhere.
/// This one goes into the family's iCloud, where a co-parent's device can read it.
/// Single-round SHA-256 of a four-digit code with a known salt is ten thousand
/// hashes — instant. So this stretches.
///
/// **PBKDF2-HMAC-SHA256, because of the floor.** CryptoKit at iOS 17 / macOS 14
/// offers HKDF and no PBKDF2, and HKDF is the wrong tool: it expands strong key
/// material, it does not stretch a weak secret. `CCKeyDerivationPBKDF` is a system
/// module, needs no dependency, and has a tunable count.
///
/// **Say the honest thing about what this buys.** No key derivation protects a
/// four-digit PIN: there are ten thousand of them, and at the iteration count
/// below exhausting the space is minutes of GPU time, not years. The real
/// protections are that the field is carried in `CKRecord.encryptedValues`, so
/// Apple's servers cannot read it, and that the only accounts holding the
/// household zone are co-parents who already have admin. This is a speed bump
/// against a co-parent's device being dumped, and against the code being reused
/// somewhere that matters more — which is the same argument the local record
/// makes. **If the passcode ever needs to resist an attacker who has the
/// verifier, the answer is more digits, not more iterations.** That is a product
/// decision and it is not made here.
public struct PasscodeVerifier: Sendable, Equatable {
    /// OWASP's 2023 floor for PBKDF2-HMAC-SHA256. High enough to be felt by an
    /// attacker and unnoticeable once, on the one screen that uses it.
    ///
    /// **Stored nowhere and therefore not tunable per record**, which is a
    /// deliberate limitation rather than an oversight: raising it later means
    /// every existing verifier stops matching, so it can only be raised by
    /// re-deriving from a passcode somebody has just typed. Written down here so
    /// whoever raises it knows that before they do.
    public static let iterations = 210_000

    public static let saltByteCount = 16
    public static let verifierByteCount = 32

    public let salt: Data
    public let verifier: Data

    public init(salt: Data, verifier: Data) {
        self.salt = salt
        self.verifier = verifier
    }

    /// Derives from a passcode and a caller-supplied salt.
    ///
    /// The salt is a parameter for the reason ``PasscodeRecord/make(_:salt:)``'s is:
    /// so a test is deterministic. ``make(_:)`` reaches for randomness.
    public static func make(_ passcode: String, salt: Data) -> PasscodeVerifier {
        PasscodeVerifier(salt: salt, verifier: derive(passcode, salt: salt))
    }

    public static func make(_ passcode: String) -> PasscodeVerifier {
        make(passcode, salt: PasscodeRecord.randomSalt(byteCount: saltByteCount))
    }

    /// Constant-time comparison, so a timing difference cannot leak how much of a
    /// guess was right — the same reason ``PasscodeRecord/matches(_:)`` does it.
    public func matches(_ passcode: String) -> Bool {
        let candidate = Self.derive(passcode, salt: salt)
        guard candidate.count == verifier.count, !verifier.isEmpty else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate, verifier) { difference |= a ^ b }
        return difference == 0
    }

    /// Returns empty on failure rather than trapping.
    ///
    /// A derivation that fails must not match anything, and ``matches(_:)`` refuses
    /// an empty verifier explicitly — the failure mode to avoid is an all-zero
    /// derivation on both sides comparing equal and opening the gate.
    static func derive(_ passcode: String, salt: Data) -> Data {
        let passwordBytes = Array(passcode.utf8)
        var derived = [UInt8](repeating: 0, count: verifierByteCount)
        let saltBytes = [UInt8](salt)

        let status = saltBytes.withUnsafeBufferPointer { saltPointer in
            derived.withUnsafeMutableBufferPointer { output in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.withUnsafeBufferPointer { $0.baseAddress },
                    passwordBytes.count,
                    saltPointer.baseAddress,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    output.baseAddress,
                    output.count
                )
            }
        }
        guard status == kCCSuccess else { return Data() }
        return Data(derived)
    }
}
