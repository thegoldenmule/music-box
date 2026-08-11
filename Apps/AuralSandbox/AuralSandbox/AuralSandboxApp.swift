import SwiftUI

@main
struct AuralSandboxApp: App {
    private enum Startup {
        case ready(Session)
        case failed(String)
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
