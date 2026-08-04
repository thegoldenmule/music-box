import CloudKit
import Foundation

/// Who is signed in, as ``BindingResolver`` needs it.
///
/// **A seam because the three unhappy answers are the interesting ones** — no
/// account, restricted by parental controls, and temporarily unreachable — and
/// none of them can be produced on demand from a test. `BindingResolver` already
/// collapses all three to ``AccountState/noOpinion``; this is the part that has
/// to decide which platform answers mean that.
public protocol AccountIdentitySource: Sendable {
    func current() async -> AccountState
}

// MARK: -

public struct CloudKitAccountIdentity: AccountIdentitySource {
    private let container: CKContainer

    public init(containerIdentifier: String = "iCloud.com.thegoldenmule.auralsanbox") {
        container = CKContainer(identifier: containerIdentifier)
    }

    /// The signed-in account's opaque record name, or no opinion.
    ///
    /// **Every failure is `noOpinion`, and that is the fail-safe direction
    /// here.** A thrown error means "we could not ask", and treating that as a
    /// *changed* account would lock a child's iPad out of their own player
    /// because the network was down. `BindingResolver` is written for exactly
    /// this: with no opinion the device binding governs and the app runs on its
    /// last imported data.
    ///
    /// `restricted` is worth naming rather than folding into the default: it is
    /// what parental controls produce, so on a child's device it is a normal
    /// steady state and not a fault.
    public func current() async -> AccountState {
        let status = try? await container.accountStatus()
        switch status {
        case .available:
            break
        case .restricted, .noAccount, .couldNotDetermine, .temporarilyUnavailable, .none:
            return .noOpinion
        @unknown default:
            return .noOpinion
        }

        guard let id = try? await container.userRecordID() else { return .noOpinion }
        return .signedIn(id.recordName)
    }
}

// MARK: -

public struct StubAccountIdentity: AccountIdentitySource {
    private let state: AccountState

    public init(_ state: AccountState = .noOpinion) { self.state = state }

    public func current() async -> AccountState { state }
}
