import AdminGate
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

    /// **Which of the four states this device is in**, rather than the boolean it
    /// used to ask. `!isPasscodeSet` conflated three of them — see
    /// ``AdminGate/PasscodeEpoch``: a device that has never had a code, a device
    /// whose code was rotated elsewhere, and a Keychain that simply would not read.
    /// Only the first may be offered a chance to choose one.
    private var challenge: PasscodeChallenge { session.passcodeChallenge }

    private var isFirstRun: Bool { challenge == .choose }

    var body: some View {
        Form {
            if challenge == .unavailable {
                unavailableSection
            } else {
                entrySection
            }

            if let message {
                Text(message).foregroundStyle(.red)
            }

            if challenge != .unavailable {
                Button(isFirstRun ? "Set passcode" : "Unlock") { submit() }
                    .disabled(!canSubmit)
            }
        }
        .navigationTitle("Admin")
        .onAppear { focused = challenge != .unavailable }
    }

    /// **Offers nothing.** The Keychain could not be read, which says nothing about
    /// whether a passcode exists — and the one thing this screen must never do in
    /// that state is offer to replace it.
    private var unavailableSection: some View {
        Section {
            Label("Can't check the passcode", systemImage: "lock.trianglebadge.exclamationmark")
        } footer: {
            Text(
                "This device can't read its own keychain right now, so it can't tell whether a passcode is set. Locking the device and unlocking it again usually fixes it. Nothing has been changed."
            )
        }
    }

    private var entrySection: some View {
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
            Text(footnote)
        }
    }

    private var footnote: String {
        switch challenge {
        case .choose:
            "Make it different from the one that unlocks this device — your kid probably knows that one. There is no way to recover it."
        case .enterHousehold:
            // Said out loud, because otherwise this reads as the app having
            // forgotten the code that worked yesterday.
            "A grown-up set or changed this family's passcode on another device. Enter the current one and this device will remember it."
        case .enterLocal, .unavailable:
            "There is no reset. That is the point."
        }
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
