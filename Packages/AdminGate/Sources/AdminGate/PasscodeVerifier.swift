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
/// **The work factor is not what makes this safe, and it does not need to be.**
/// No derivation protects a four-digit PIN — ten thousand candidates is minutes of
/// GPU time at any iteration count. That is fine here, because of who the attacker
/// would have to be.
///
/// Reaching this verifier means extracting a private CloudKit zone from a family's
/// iCloud account and then brute-forcing offline. **A child who can do that has
/// already beaten Screen Time**, which is the containment this app openly says it
/// cannot enforce and does not try to — see the containment-fails-open rule. The
/// gate stands between a child and a settings screen; it was never a barrier
/// against someone with the family's iCloud data in hand, and building it as one
/// would be spending effort where the threat model has already collapsed.
///
/// So the iteration count is here to make the cheap attack not free, and the real
/// properties are elsewhere: the field is carried in `CKRecord.encryptedValues` so
/// Apple's servers cannot read it, and the household zone is held only by
/// co-parents who already have admin anyway. The one residual worth a sentence is
/// a parent reusing this PIN somewhere that matters more, which is exactly the
/// concern ``PasscodeRecord`` already names for the local hash.
///
/// If it ever *does* need to resist someone holding the verifier, the answer is
/// more digits rather than more iterations. That is a product decision.
public struct PasscodeVerifier: Sendable, Equatable {
    /// OWASP's 2023 floor. Not tunable per record — raising it breaks old verifiers.
    public static let iterations = 210_000

    public static let saltByteCount = 16
    public static let verifierByteCount = 32

    public let salt: Data
    public let verifier: Data

    public init(salt: Data, verifier: Data) {
        self.salt = salt
        self.verifier = verifier
    }

    /// Salt is a parameter for test determinism, like `PasscodeRecord.make(_:salt:)`.
    public static func make(_ passcode: String, salt: Data) -> PasscodeVerifier {
        PasscodeVerifier(salt: salt, verifier: derive(passcode, salt: salt))
    }

    public static func make(_ passcode: String) -> PasscodeVerifier {
        make(passcode, salt: PasscodeRecord.randomSalt(byteCount: saltByteCount))
    }

    /// Constant-time, like `PasscodeRecord.matches`, so timing can't leak progress.
    public func matches(_ passcode: String) -> Bool {
        let candidate = Self.derive(passcode, salt: salt)
        guard candidate.count == verifier.count, !verifier.isEmpty else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate, verifier) { difference |= a ^ b }
        return difference == 0
    }

    /// Empty on failure, not a trap — `matches` refuses empty so failures can't match.
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
