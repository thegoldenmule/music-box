import CloudKit
import SwiftUI

/// Where a tapped invitation link waits until something can act on it.
///
/// **It exists because the two halves cannot meet directly.** The system hands a
/// tapped share to an application delegate it constructed itself, and the only
/// thing that can accept one is `Session`, which is `@State` inside the `App`.
/// On a cold launch the delegate runs *first* — there is no session yet — so the
/// metadata has to be put somewhere that outlives the callback and be collected
/// afterwards.
///
/// **A queue rather than a slot.** Two links tapped in quick succession is
/// unlikely and dropping the first would be silent, which is the one thing this
/// file exists to prevent: an invitation that vanished looks exactly like an
/// invitation nobody sent.
@MainActor
@Observable
final class ShareAcceptance {
    /// One inbox for the process, because the delegate has no way to be handed
    /// one. This is the only global in the app and it holds no decisions — see
    /// ``Session/acceptPendingShares()`` for the part that does anything.
    static let shared = ShareAcceptance()

    /// What happened to the last invitation this device accepted.
    ///
    /// Kept so the admin's sharing screen can say so afterwards. It cannot be
    /// reported at the moment it happens: a tapped link on a shared iPad lands
    /// while the kid's player is on screen, and nothing about the household's
    /// grown-ups belongs there.
    enum Outcome: Equatable {
        case joined
        case failed(String)
    }

    private(set) var waiting: [CKShare.Metadata] = []
    private(set) var outcome: Outcome?

    /// Bumped on every acceptance so a screen already open redraws its roster.
    private(set) var acceptances = 0

    private init() {}

    func received(_ metadata: CKShare.Metadata) {
        waiting.append(metadata)
    }

    /// Takes everything waiting, leaving the inbox empty.
    ///
    /// Drained rather than read so two callers cannot both accept the same
    /// invitation — `RootView` collects on launch and again on foreground, and
    /// those overlap.
    func drain() -> [CKShare.Metadata] {
        defer { waiting = [] }
        return waiting
    }

    func record(_ outcome: Outcome) {
        self.outcome = outcome
        if outcome == .joined { acceptances += 1 }
    }

    func clearOutcome() {
        outcome = nil
    }
}

// MARK: - The delegate the system talks to

/// Catches a tapped invitation link.
///
/// **`CKSharingSupported` in `Info.plist` only gets the app launched.** Without
/// this method the system hands the share to nobody and the tap does nothing at
/// all — no error, no screen, no record — which is why the sharing screen used to
/// promise a link tap would work while paste was the only path that did.
///
/// It does not accept anything itself. Accepting needs the container and the
/// store, and a delegate that reached for either would be a second place that
/// decides how a household is joined.
#if canImport(UIKit)
    final class ShareAcceptanceDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
        ) {
            ShareAcceptance.shared.received(metadata)
        }
    }
#else
    final class ShareAcceptanceDelegate: NSObject, NSApplicationDelegate {
        func application(
            _ application: NSApplication,
            userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
        ) {
            ShareAcceptance.shared.received(metadata)
        }
    }
#endif
