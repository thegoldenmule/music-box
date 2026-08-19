import Foundation
import Testing

@testable import AdminGate

/// A Keychain-error state the in-memory store can never be in.
private struct UnreadablePasscodeStore: PasscodeStore {
    struct Broken: Error {}

    func record() throws -> PasscodeRecord? { throw Broken() }
    func save(_ record: PasscodeRecord) throws { throw Broken() }
    func clear() throws { throw Broken() }
}

@Suite("Whether this device has a gate")
struct PasscodeAvailabilityTests {
    @Test("A store with a record is configured")
    func configured() {
        let store = InMemoryPasscodeStore(PasscodeRecord.make("1234"))
        #expect(store.availability == .configured)
        #expect(store.isConfigured)
    }

    @Test("An empty store is absent, and only that state may offer to choose one")
    func absent() {
        let store = InMemoryPasscodeStore()
        #expect(store.availability == .absent)
        #expect(store.isConfigured == false)
    }

    /// The bug this guards: a throw once let the UI offer to **choose** a new code.
    @Test("A store that cannot be read is neither configured nor absent")
    func unreadableIsItsOwnState() {
        let store = UnreadablePasscodeStore()
        #expect(store.availability == .unreadable)
    }

    @Test("Unreadable fails closed: it counts as having a gate")
    func unreadableFailsClosed() {
        let store = UnreadablePasscodeStore()

        // Failing open would hand the gate to whoever holds the device — the kid.
        #expect(store.isConfigured)
    }
}
