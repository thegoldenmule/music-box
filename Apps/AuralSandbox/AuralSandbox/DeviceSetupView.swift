import FamilyStore
import FamilySync
import SwiftUI

/// What this device is for, asked once.
///
/// **A screen rather than a default, because the wrong answer is invisible.**
/// Until now the active kid was whoever the roster listed first, so a
/// seven-year-old's iPad could open into his twelve-year-old sister's
/// `reportOnly` sandbox — the wrong policy level, another child's library, and
/// every play filed under the wrong name. All three of those look exactly like
/// the app working.
///
/// Deliberately not behind the admin gate. It runs before there is anything to
/// gate: a device with no row has no binding, and a parent setting up a child's
/// iPad is standing next to it.
struct DeviceSetupView: View {
    @Bindable var session: Session

    @State private var role: EnrollmentRole = .kidOnly
    @State private var label: String = Session.suggestedDeviceLabel
    @State private var boundKidID: UUID?
    @State private var refusal: EnrollmentRefusal?
    @State private var newPasscode = ""
    @State private var passcodeTrouble: String?

    var body: some View {
        Form {
            Section {
                Picker("This device is", selection: $role) {
                    Text("A child's own").tag(EnrollmentRole.kidOnly)
                    Text("Shared").tag(EnrollmentRole.both)
                    Text("A grown-up's").tag(EnrollmentRole.parentOnly)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("What is this device for?")
            } footer: {
                Text(explanation)
            }

            if role.isPlayer {
                Section {
                    Picker("Opens into", selection: $boundKidID) {
                        Text("Ask each time").tag(UUID?.none)
                        ForEach(session.kids, id: \.id) { kid in
                            Text(kid.name).tag(UUID?.some(kid.id))
                        }
                    }
                } header: {
                    Text("Whose music")
                } footer: {
                    Text(
                        "This is the child this device opens into every time. A grown-up can change it behind the passcode."
                    )
                }
            }

            if role.isPlayer && !session.isPasscodeSet {
                passcodeSection
            }

            Section {
                TextField("Name", text: $label)
            } header: {
                Text("Call it")
            } footer: {
                Text("So you can tell it apart in the family's device list.")
            }

            Section {
                Button("Done") { save() }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                // The refusal's own words, which say what to do rather than what
                // is wrong — see `EnrollmentRefusal.explanation`.
                if let refusal {
                    Text(refusal.explanation).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Set up this device")
    }

    /// **Setting the passcode here is what stops this screen being a trap.**
    /// `Enrollment` refuses to point a device at a child until one exists, and
    /// the only other place to set one is behind the gate — which is inside the
    /// player this screen is standing in front of. Without this, a family whose
    /// device has no code could not finish setup and could not reach the screen
    /// that says how.
    ///
    /// It also puts the code where the reason for it is: a parent is being told
    /// why a child's device needs one at the moment they are deciding it is a
    /// child's device.
    private var passcodeSection: some View {
        Section {
            SecureField("New passcode", text: $newPasscode)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
            Button("Set passcode") {
                passcodeTrouble = session.setPasscode(newPasscode)
                if passcodeTrouble == nil {
                    newPasscode = ""
                    refusal = nil
                }
            }
            .disabled(newPasscode.isEmpty)
            if let passcodeTrouble {
                Text(passcodeTrouble).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Admin passcode")
        } footer: {
            Text(
                "A child's device needs one before it can open into their music. It is what keeps the settings — and everything this app records about them — out of reach of whoever is holding it."
            )
        }
    }

    private var explanation: String {
        switch role {
        case .kidOnly:
            "Opens straight into your child's music. Everything a grown-up needs is behind the passcode."
        case .both:
            "Opens into your child's music, and goes back to it when a grown-up leaves the admin screens."
        case .parentOnly:
            "No player at all. For a phone you use to manage what your children can reach."
        }
    }

    private func save() {
        refusal = session.enroll(
            role: role,
            label: label.trimmingCharacters(in: .whitespaces),
            boundKidID: role.isPlayer ? boundKidID : nil
        )
    }
}

// MARK: -

/// What a device shows when it has an answer and the answer is no.
///
/// **Says both facts and offers nothing else.** `BindingResolver`'s rule is that
/// a mismatch locks and never falls back — no nearest kid, no first kid — so
/// this screen must not quietly become a picker. A parent reading it needs to
/// know what the device thinks happened; a child reading it needs it to be a
/// dead end.
struct DeviceLockedView: View {
    let reason: LockReason
    let kids: [Kid]

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(explanation)
        }
        .padding()
    }

    private var title: String {
        switch reason {
        case .revoked: "This device was removed"
        case .accountChanged: "Someone else is signed in"
        case .boundKidMissing: "That child isn't here any more"
        case .notBound: "Nobody has said whose this is"
        case .noGate: "This device needs a passcode"
        }
    }

    private var icon: String {
        switch reason {
        case .revoked: "hand.raised"
        case .accountChanged: "person.crop.circle.badge.exclamationmark"
        case .boundKidMissing: "questionmark.circle"
        case .notBound: "person.crop.circle.dashed"
        case .noGate: "lock.open"
        }
    }

    private var explanation: String {
        switch reason {
        case .revoked:
            "A grown-up removed this device from the family. They can let it back in from the device list on another device."
        case .accountChanged:
            // Deliberately does not print either account name. It is an opaque
            // record identifier, it means nothing to a person, and showing one
            // Apple Account's identifier to whoever is holding the device now is
            // not information they are owed.
            "This device was set up under a different Apple Account than the one signed in now. A grown-up can set it up again."
        case .boundKidMissing(let id):
            "This device opens into a child who is no longer in this family\(named(id)). A grown-up can point it at somebody else."
        case .notBound:
            "This device is part of the family, but nobody has chosen which child it opens into yet."
        case .noGate(let id):
            // The one lock with a fix the person holding it can do, so it is the
            // one that says how.
            "Set an admin passcode before\(named(id, possessive: true)) music opens here. Without one, anybody holding this device could change what they are allowed to reach."
        }
    }

    /// Names the child when we still know it, and says nothing when we do not —
    /// rather than printing a UUID at a parent.
    private func named(_ id: UUID, possessive: Bool = false) -> String {
        guard let kid = kids.first(where: { $0.id == id }) else {
            return possessive ? " your child's" : ""
        }
        return possessive ? " \(kid.name)'s" : " (\(kid.name))"
    }
}
