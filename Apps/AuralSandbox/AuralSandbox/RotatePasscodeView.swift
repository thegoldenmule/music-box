import AdminGate
import SwiftUI

/// Changing the family's passcode.
///
/// **The first revocation path this app has ever had.** Before this, `setPasscode`
/// refused once a code existed and `PasscodeStore.clear()` had no caller anywhere,
/// so a code a child had watched being typed could not be replaced. Writing a new
/// epoch is what takes it back: every other device reads its own local item as
/// stale and demands the new code — see ``AdminGate/PasscodeEpoch``.
///
/// **It requires the current code even though the parent is already through the
/// gate.** The gate stays open for a while after one entry, and "already inside"
/// is not the same as "knows the code" on a device somebody left unlocked. This is
/// the one screen where that difference is worth a second prompt.
struct RotatePasscodeView: View {
    @Bindable var session: Session

    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var done = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                SecureField("Current passcode", text: $current)
                    .textContentType(.password)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }

            Section {
                SecureField("New passcode", text: $new)
                    .textContentType(.newPassword)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                SecureField("Confirm", text: $confirmation)
                    .textContentType(.newPassword)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            } footer: {
                Text(
                    "There is still no way to recover it. Make it different from the code that unlocks this device."
                )
            }

            if let message {
                Text(message).foregroundStyle(.red)
            }

            if done {
                Label(
                    "Changed. Other devices will ask for the new one when they next sync.",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.secondary)
            }

            Button("Change it") { submit() }
                .disabled(!canSubmit)
        }
        .navigationTitle("Passcode")
    }

    private var canSubmit: Bool {
        guard !current.isEmpty, !new.isEmpty, new == confirmation else { return false }
        // Backoff is enforced in the model too; this is a courtesy, not the control.
        guard session.retryDelay == nil else { return false }
        // Refusing a no-op rather than writing an epoch for it: every other device
        // would demand a "new" code identical to the old one, which reads as the
        // family's gate having broken.
        return new != current
    }

    private func submit() {
        session.touchAdmin()
        let failure = session.rotatePasscode(current: current, to: new)

        current = ""
        new = ""
        confirmation = ""

        if let failure {
            message = failure
            done = false
        } else {
            message = nil
            done = true
        }
    }
}
