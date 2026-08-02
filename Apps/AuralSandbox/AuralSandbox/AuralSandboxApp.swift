import SwiftUI

@main
struct AuralSandboxApp: App {
    private enum Startup {
        case ready(Session)
        case failed(String)
    }

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

    /// Set by `-runCloudKitProbe YES`, so the probes can be run and their
    /// output captured without anyone tapping through the gate. Throwaway,
    /// alongside the probe screen itself.
    private var isProbing: Bool {
        UserDefaults.standard.bool(forKey: "runCloudKitProbe")
    }

    var body: some Scene {
        WindowGroup {
            if isProbing {
                Color.clear.task {
                    await CloudKitProbe.runHeadless()
                    print("probe finished")
                }
            } else {
                switch startup {
                case .ready(let session):
                    RootView(session: session)
                case .failed(let message):
                    StartupFailureView(message: message)
                }
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
