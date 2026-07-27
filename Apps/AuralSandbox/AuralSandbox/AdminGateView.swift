import SwiftUI

/// The passcode gate. Every route into the admin comes through here.
///
/// Two paths, decided by whether a passcode exists yet: choose one on first
/// run, enter it every time after. There is deliberately **no third path** —
/// no reset, no recovery, no "forgot it?". A reset a kid could drive is not a
/// gate, and this is the whole mechanism standing between a child and their own
/// settings.
///
/// That makes losing the passcode a dead end, which is the honest argument for
/// biometrics later rather than a back door now.
struct AdminGateView: View {
    @Bindable var session: Session
    var onOpen: () -> Void

    @State private var entry = ""
    @State private var confirmation = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    private var isFirstRun: Bool { !session.isPasscodeSet }

    var body: some View {
        Form {
            Section {
                SecureField("Passcode", text: $entry)
                    .focused($focused)
                    .textContentType(.password)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif

                if isFirstRun {
                    SecureField("Confirm", text: $confirmation)
                        .textContentType(.password)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                }
            } header: {
                Text(isFirstRun ? "Choose an admin passcode" : "Enter the admin passcode")
            } footer: {
                Text(
                    isFirstRun
                        ? "Make it different from the one that unlocks this device — your kid probably knows that one. There is no way to recover it."
                        : "There is no reset. That is the point."
                )
            }

            if let message {
                Text(message).foregroundStyle(.red)
            }

            Button(isFirstRun ? "Set passcode" : "Unlock") { submit() }
                .disabled(!canSubmit)
        }
        .navigationTitle("Admin")
        .onAppear { focused = true }
    }

    private var canSubmit: Bool {
        guard !entry.isEmpty else { return false }
        // Backoff is enforced in the model too; disabling the button is a
        // courtesy, not the control.
        guard session.retryDelay == nil else { return false }
        return isFirstRun ? entry == confirmation : true
    }

    private func submit() {
        let failure =
            isFirstRun
            ? session.setPasscode(entry)
            : session.unlockAdmin(with: entry)

        entry = ""
        confirmation = ""

        if let failure {
            message = failure
        } else {
            message = nil
            onOpen()
        }
    }
}
