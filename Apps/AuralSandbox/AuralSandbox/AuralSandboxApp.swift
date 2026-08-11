import SwiftUI

@main
struct AuralSandboxApp: App {
    private enum Startup {
        case ready(Session)
        case failed(String)
        /// Throwaway — goes with ``SharingProbe``.
        case probing
    }

    /// Only there to catch a tapped invitation link — see
    /// ``ShareAcceptanceDelegate``. The system constructs the delegate, so it
    /// cannot be handed the session; it puts the share in ``ShareAcceptance``
    /// and ``RootView`` collects it.
    #if canImport(UIKit)
        @UIApplicationDelegateAdaptor(ShareAcceptanceDelegate.self) private var delegate
    #else
        @NSApplicationDelegateAdaptor(ShareAcceptanceDelegate.self) private var delegate
    #endif

    /// Built once. A failure here means the store would not open, which is the
    /// one startup failure worth showing rather than retrying — see
    /// ``StartupFailureView``.
    @State private var startup: Startup = {
        // Throwaway — goes with ``SharingProbe``. Ahead of the store on purpose:
        // the probe asks CloudKit questions and has no business opening a family's
        // data to do it.
        if SharingProbe.isRequested { return .probing }
        do {
            return .ready(try Session())
        } catch {
            return .failed(Session.message(for: error))
        }
    }()

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .ready(let session):
                RootView(session: session)
            case .failed(let message):
                StartupFailureView(message: message)
            case .probing:
                // Throwaway — goes with ``SharingProbe``.
                Text("probing…").task { await SharingProbe.runAndExit() }
            }
        }
        #if os(macOS)
            .defaultSize(width: 520, height: 720)
        #endif
    }
}

struct StartupFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't open the store", systemImage: "externaldrive.badge.xmark")
        } description: {
            // The lists are the irreplaceable part. Say what was lost rather
            // than starting silently empty.
            Text(message)
        }
        .padding()
    }
}
