import Foundation
import Testing

@testable import AdminGate

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ seconds: TimeInterval) -> Date { t0 + seconds }

// MARK: - Sessions

@Suite("Sessions")
struct Sessions {
    @Test("A new gate is closed")
    func startsClosed() {
        #expect(AdminGate().isOpen(at: t0) == false)
    }

    @Test("A correct passcode opens it")
    func opens() {
        var gate = AdminGate()
        gate.succeeded(at: t0)
        #expect(gate.isOpen(at: t0))
    }

    @Test("It closes itself once the idle timeout lapses")
    func expires() {
        var gate = AdminGate()
        gate.succeeded(at: t0)

        #expect(gate.isOpen(at: at(AdminGate.idleTimeout - 1)))
        #expect(gate.isOpen(at: at(AdminGate.idleTimeout)) == false)
    }

    @Test("Activity extends the session")
    func touchExtends() {
        var gate = AdminGate()
        gate.succeeded(at: t0)
        gate.touch(at: at(200))

        #expect(gate.isOpen(at: at(400)))
    }

    @Test("Activity cannot reopen a session that already lapsed")
    func touchCannotResurrect() {
        var gate = AdminGate()
        gate.succeeded(at: t0)
        // One second past the timeout: the session is gone, and nudging it must
        // not bring it back without anyone entering anything.
        gate.touch(at: at(AdminGate.idleTimeout + 1))

        #expect(gate.isOpen(at: at(AdminGate.idleTimeout + 2)) == false)
    }

    @Test("Closing shuts it immediately")
    func closes() {
        var gate = AdminGate()
        gate.succeeded(at: t0)
        gate.close()

        #expect(gate.isOpen(at: t0) == false)
    }

    @Test("A wrong passcode closes any open session")
    func failureClosesSession() {
        var gate = AdminGate()
        gate.succeeded(at: t0)
        gate.failed(at: at(1))

        #expect(gate.isOpen(at: at(2)) == false)
    }
}

// MARK: - Backoff

@Suite("Backoff")
struct Backoff {
    @Test("The first few wrong guesses cost nothing", arguments: 1...AdminGate.freeAttempts)
    func freeAttempts(count: Int) {
        var gate = AdminGate()
        var last: TimeInterval?
        for _ in 0..<count {
            last = gate.failed(at: t0)
        }

        #expect(last == nil)
        #expect(gate.isAcceptingAttempts(at: t0))
    }

    @Test("Past that, waiting starts and doubles")
    func doubles() {
        var gate = AdminGate()
        for _ in 0..<AdminGate.freeAttempts {
            gate.failed(at: t0)
        }

        #expect(gate.failed(at: t0) == 5)
        #expect(gate.failed(at: t0) == 10)
        #expect(gate.failed(at: t0) == 20)
        #expect(gate.failed(at: t0) == 40)
    }

    @Test("The wait is capped")
    func caps() {
        var gate = AdminGate()
        var delay: TimeInterval?
        for _ in 0..<40 {
            delay = gate.failed(at: t0)
        }

        // Unbounded doubling bricks the app for a parent long before it deters
        // a kid, who has all afternoon regardless.
        #expect(delay == AdminGate.maxDelay)
    }

    @Test("Attempts are refused until the wait is over")
    func refusesDuringBackoff() {
        var gate = AdminGate()
        for _ in 0...AdminGate.freeAttempts {
            gate.failed(at: t0)
        }

        #expect(gate.isAcceptingAttempts(at: t0) == false)
        #expect(gate.retryDelay(at: at(1)) == 4)
        #expect(gate.isAcceptingAttempts(at: at(5)))
        #expect(gate.retryDelay(at: at(5)) == nil)
    }

    @Test("Getting it right clears the backoff")
    func successResets() {
        var gate = AdminGate()
        for _ in 0...AdminGate.freeAttempts {
            gate.failed(at: t0)
        }
        gate.succeeded(at: at(10))

        #expect(gate.failedAttempts == 0)
        #expect(gate.retryDelay(at: at(10)) == nil)
        #expect(gate.failed(at: at(11)) == nil)
    }

    @Test("Backgrounding does not clear the backoff")
    func closeKeepsBackoff() {
        var gate = AdminGate()
        for _ in 0...AdminGate.freeAttempts {
            gate.failed(at: t0)
        }
        gate.close()

        // Otherwise the penalty is one app switch away from being free.
        #expect(gate.isAcceptingAttempts(at: t0) == false)
    }
}

// MARK: - Passcodes

@Suite("Passcodes")
struct Passcodes {
    private let salt = Data(repeating: 0xAB, count: 16)

    @Test("The right passcode matches")
    func matches() {
        #expect(PasscodeRecord.make("1234", salt: salt).matches("1234"))
    }

    @Test("A wrong one does not", arguments: ["1235", "123", "12345", "", "4321"])
    func rejects(candidate: String) {
        #expect(PasscodeRecord.make("1234", salt: salt).matches(candidate) == false)
    }

    @Test("The passcode itself is never in the stored bytes")
    func doesNotStorePasscode() {
        let record = PasscodeRecord.make("8675309", salt: salt)
        #expect(record.hash.contains(Data("8675309".utf8)) == false)
    }

    @Test("The same passcode under different salts hashes differently")
    func saltMatters() {
        let a = PasscodeRecord.make("1234", salt: Data(repeating: 0x01, count: 16))
        let b = PasscodeRecord.make("1234", salt: Data(repeating: 0x02, count: 16))
        #expect(a.hash != b.hash)
    }

    @Test("Generated salts differ")
    func randomSalts() {
        #expect(PasscodeRecord.randomSalt() != PasscodeRecord.randomSalt())
    }
}

// MARK: - Storage seam

@Suite("Passcode storage")
struct Storage {
    @Test("No passcode set reads as nil, which is what puts first run in setup")
    func emptyIsNil() throws {
        #expect(try InMemoryPasscodeStore().record() == nil)
    }

    @Test("Saving then reading round-trips")
    func roundTrip() throws {
        let store = InMemoryPasscodeStore()
        let record = PasscodeRecord.make("1234")
        try store.save(record)

        #expect(try store.record() == record)
        #expect(try #require(try store.record()).matches("1234"))
    }

    @Test("Saving twice replaces rather than appending")
    func replaces() throws {
        let store = InMemoryPasscodeStore()
        try store.save(PasscodeRecord.make("1111"))
        try store.save(PasscodeRecord.make("2222"))

        let stored = try #require(try store.record())
        #expect(stored.matches("2222"))
        #expect(stored.matches("1111") == false)
    }

    @Test("Clearing removes it")
    func clears() throws {
        let store = InMemoryPasscodeStore()
        try store.save(PasscodeRecord.make("1234"))
        try store.clear()

        #expect(try store.record() == nil)
    }
}
