import Foundation
import Testing

@testable import AdminGate

private enum Fix {
    static let salt = Data(repeating: 7, count: PasscodeVerifier.saltByteCount)
    static func gate(_ epoch: Int, code: String = "1234") -> HouseholdGate {
        HouseholdGate(epoch: epoch, verifier: PasscodeVerifier.make(code, salt: salt))
    }
}

// MARK: -

@Suite("A verifier that can leave the device")
struct TheVerifier {
    @Test("The right code matches and a wrong one does not")
    func matches() {
        let verifier = PasscodeVerifier.make("1234", salt: Fix.salt)
        #expect(verifier.matches("1234"))
        #expect(!verifier.matches("1235"))
        #expect(!verifier.matches(""))
    }

    @Test("The same code and salt derive the same bytes on any device")
    func deterministic() {
        #expect(
            PasscodeVerifier.make("1234", salt: Fix.salt)
                == PasscodeVerifier.make("1234", salt: Fix.salt))
    }

    @Test("A different salt gives a different verifier for the same code")
    func salted() {
        let other = Data(repeating: 9, count: PasscodeVerifier.saltByteCount)
        #expect(
            PasscodeVerifier.make("1234", salt: Fix.salt).verifier
                != PasscodeVerifier.make("1234", salt: other).verifier)
    }

    /// The failure to avoid: two failed derivations both zero, comparing equal.
    @Test("An empty verifier matches nothing")
    func emptyMatchesNothing() {
        let empty = PasscodeVerifier(salt: Fix.salt, verifier: Data())
        #expect(!empty.matches("1234"))
        #expect(!empty.matches(""))
    }

    @Test("It is a different derivation from the local record's")
    func differsFromLocal() {
        let local = PasscodeRecord.make("1234", salt: Fix.salt)
        #expect(PasscodeVerifier.make("1234", salt: Fix.salt).verifier != local.hash)
    }
}

// MARK: -

@Suite("What the gate asks for")
struct TheChallenge {
    @Test("Nobody has ever set a code, so choose one")
    func firstRun() {
        #expect(
            PasscodeEpoch.challenge(local: .absent, localEpoch: 0, household: nil) == .choose)
    }

    @Test("This device holds the current code, so check it locally")
    func localFastPath() {
        #expect(
            PasscodeEpoch.challenge(local: .configured, localEpoch: 3, household: Fix.gate(3))
                == .enterLocal)
    }

    /// Must work with no network — equal epochs never consult the household.
    @Test("A household nobody has told us about leaves the local item governing")
    func noRecordYet() {
        #expect(
            PasscodeEpoch.challenge(local: .configured, localEpoch: 0, household: nil)
                == .enterLocal)
    }

    /// The bypass this closes: join, then set your own code on the child's device.
    @Test("A device with no code in a household that has one must enter, never choose")
    func joinedDeviceMustEnter() {
        #expect(
            PasscodeEpoch.challenge(local: .absent, localEpoch: 0, household: Fix.gate(1))
                == .enterHousehold(epoch: 1))
    }

    @Test("A rotated code makes a device holding the old one stale")
    func rotationInvalidates() {
        #expect(
            PasscodeEpoch.challenge(local: .configured, localEpoch: 1, household: Fix.gate(2))
                == .enterHousehold(epoch: 2))
    }

    /// A pre-epoch install carries 0, sorting stale once a household epoch appears.
    @Test("A pre-epoch local item is stale once the household has an epoch")
    func preEpochIsStale() {
        #expect(
            PasscodeEpoch.challenge(
                local: .configured, localEpoch: 0, household: Fix.gate(PasscodeEpoch.first))
                == .enterHousehold(epoch: PasscodeEpoch.first))
    }

    /// A device ahead never re-enters: its item is current, the record just lags.
    @Test("A device ahead of the household still checks locally")
    func aheadIsFine() {
        #expect(
            PasscodeEpoch.challenge(local: .configured, localEpoch: 4, household: Fix.gate(3))
                == .enterLocal)
    }

    /// Unreadable is never absent — must never offer to replace the code.
    @Test("An unreadable Keychain offers nothing at all")
    func unreadableOffersNothing() {
        for household in [nil, Fix.gate(1)] {
            #expect(
                PasscodeEpoch.challenge(
                    local: .unreadable, localEpoch: 0, household: household) == .unavailable)
        }
    }
}

// MARK: -

@Suite("Which epoch a rotation writes")
struct TheNextEpoch {
    @Test("The first gate a household sets is epoch one")
    func first() {
        #expect(PasscodeEpoch.next(after: nil) == PasscodeEpoch.first)
    }

    @Test("A rotation is one past what is known")
    func monotonic() {
        #expect(PasscodeEpoch.next(after: Fix.gate(4)) == 5)
    }

    /// Concurrent rotations agree on one number, so the merge settles it, not a clock.
    @Test("Two rotations from the same knowledge agree on the number")
    func concurrentAgree() {
        #expect(PasscodeEpoch.next(after: Fix.gate(4)) == PasscodeEpoch.next(after: Fix.gate(4)))
    }
}

// MARK: -

@Suite("The local item's bytes")
struct LocalEncoding {
    /// The bug this guards: `decode` once read a 48-byte item's hash tail as an epoch.
    @Test("An item written before epochs existed still reads, at epoch zero")
    func legacyStillReads() throws {
        let original = PasscodeRecord.make("1234", salt: Fix.salt)
        let legacyBytes = Data(original.salt) + Data(original.hash)
        #expect(legacyBytes.count == 48)

        let store = KeychainPasscodeStore()
        let decoded = try store.decodeForTests(legacyBytes)

        #expect(decoded.epoch == 0)
        #expect(decoded.matches("1234"))
        #expect(!decoded.matches("9999"))
    }

    @Test("An item with an epoch round-trips")
    func currentRoundTrips() throws {
        let store = KeychainPasscodeStore()
        let record = PasscodeRecord.make("4321", salt: Fix.salt, epoch: 7)

        let decoded = try store.decodeForTests(store.encodeForTests(record))

        #expect(decoded.epoch == 7)
        #expect(decoded.matches("4321"))
        #expect(decoded == record)
    }

    @Test("Bytes that are neither length are corrupt rather than a passcode")
    func neitherLengthIsCorrupt() {
        let store = KeychainPasscodeStore()
        #expect(throws: KeychainPasscodeStore.Failure.corrupt) {
            try store.decodeForTests(Data(repeating: 1, count: 50))
        }
    }
}
