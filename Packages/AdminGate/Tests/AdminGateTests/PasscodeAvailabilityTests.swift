import Foundation
import Testing

@testable import AdminGate

/// A store whose reads fail, which is the state the real one can be in and the
/// in-memory one never is. The Keychain returns errors — a locked device before
/// first unlock, a damaged item, an entitlement that did not survive a
/// provisioning change — and every one of those used to read as "no passcode
/// has been set".
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

    /// The one this exists for. `((try? record()) ?? nil) != nil` collapsed the
    /// throw into `nil`, so a device holding a family's entire policy set and
    /// every child's search history offered to **choose** a new passcode — and
    /// `setPasscode` guards on this and nothing else, so it would have taken it.
    @Test("A store that cannot be read is neither configured nor absent")
    func unreadableIsItsOwnState() {
        let store = UnreadablePasscodeStore()
        #expect(store.availability == .unreadable)
    }

    @Test("Unreadable fails closed: it counts as having a gate")
    func unreadableFailsClosed() {
        let store = UnreadablePasscodeStore()

        // Failing closed costs an adult a confusing screen on a device whose
        // Keychain is broken, and they can still get in with the code they know.
        // Failing open hands the gate to whoever is holding the device, which on
        // the kid's iPad is the child.
        #expect(store.isConfigured)
    }
}
