import FamilyStore
import FamilySync
import SwiftUI

/// Every device in the family, and what a parent can do about each one.
///
/// **The screen two pieces of copy already promised.** `DeviceLockedView` tells a
/// revoked device that "a grown-up can let it back in from the device list", and
/// `DeviceSetupView` tells a parent that which child a device opens into can be
/// changed "behind the passcode". Neither was true: `DeviceRecord.revoke()` and
/// `restore()` had no caller anywhere in the app, and enrolment was a one-time
/// screen with no way back to it.
///
/// **Reading it is as much of the point as changing it.** `lastSeenAt` is the only
/// honest way to show a parent that a deny has not reached a child's iPad yet —
/// without it, "I blocked that" and "I blocked that and it arrived" look identical
/// from here.
struct DeviceRosterView: View {
    @Bindable var session: Session

    /// Loaded rather than re-fetched per redraw, and reloaded after every action.
    /// A handful of rows, and every action changes the list.
    @State private var devices: [DeviceRecord] = []
    @State private var renaming: DeviceRecord?
    @State private var trouble: String?

    var body: some View {
        Form {
            if devices.isEmpty {
                Section {
                    Text("No devices have been set up yet.").foregroundStyle(.secondary)
                }
            }

            ForEach(devices.filter { !$0.isRevoked }, id: \.id) { device in
                section(for: device)
            }

            if devices.contains(where: \.isRevoked) { revokedSection }
        }
        .navigationTitle("Devices")
        .task { reload() }
        .sheet(item: $renaming) { device in
            RenameDeviceSheet(device: device) { newLabel in
                session.touchAdmin()
                session.rename(device, to: newLabel)
                reload()
            }
        }
        .alert(
            "Couldn't do that",
            isPresented: Binding(get: { trouble != nil }, set: { if !$0 { trouble = nil } }),
            actions: { Button("OK") { trouble = nil } },
            message: { Text(trouble ?? "") }
        )
    }

    // MARK: - One device

    @ViewBuilder
    private func section(for device: DeviceRecord) -> some View {
        let isThisDevice = session.isThisDevice(device)
        let role = EnrollmentRole(rawValue: device.roleRaw) ?? .parentOnly

        Section {
            // **Editable on this device and stated on any other.** The role is
            // what a device was set up as and there was no way back to that
            // screen; see `Session.setRole(_:on:)` for why it stops here.
            if isThisDevice {
                Picker("This device is", selection: roleBinding(of: device)) {
                    Text("A child's own").tag(EnrollmentRole.kidOnly)
                    Text("Shared").tag(EnrollmentRole.both)
                    Text("A grown-up's").tag(EnrollmentRole.parentOnly)
                }
            } else {
                LabeledContent("Set up as", value: description(of: role))
            }

            if role.isPlayer {
                Picker("Opens into", selection: boundKid(of: device)) {
                    Text("Ask each time").tag(UUID?.none)
                    ForEach(session.kids, id: \.id) { kid in
                        Text(kid.name).tag(UUID?.some(kid.id))
                    }
                }
            } else {
                // Named rather than omitted: a row with no "opens into" line reads
                // as a device somebody forgot to finish setting up.
                LabeledContent("Opens into", value: "Nobody — a grown-up's device")
            }

            LabeledContent("Last heard from", value: lastSeen(device))

            Button("Rename") { renaming = device }

            // **No remove button on the device in hand.** See `Session.revoke(_:)`
            // — it locks the device into a dead end whose only way out is this
            // screen. A disabled button would raise the same question and answer
            // it nowhere.
            if !isThisDevice {
                Button("Remove from the family", role: .destructive) {
                    session.touchAdmin()
                    trouble = session.revoke(device)
                    reload()
                }
            }
        } header: {
            HStack {
                Label(device.label, systemImage: glyph(for: device))
                if isThisDevice {
                    Text("· this one").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(explanation(role: role, isThisDevice: isThisDevice, device: device))
        }
    }

    /// **Ordered so the state that needs saying most is said.** A player device
    /// pointed at nobody is the case a parent will otherwise misread: it does not
    /// quietly pick a child — `BindingResolver` refuses to fall back, so the device
    /// shows its setup screen instead, and "Ask each time" is a fair description of
    /// that only if somebody says what the asking looks like.
    private func explanation(role: EnrollmentRole, isThisDevice: Bool, device: DeviceRecord)
        -> String
    {
        guard role.isPlayer else { return "A grown-up's device. It has no player at all." }

        guard device.boundKidID != nil else {
            return
                "Until this points at a child, the device asks whoever is holding it — it never picks one. Nothing plays in the meantime."
        }

        if !isThisDevice {
            // The one rule this screen cannot enforce and must therefore state.
            // The passcode is a fact about that device's Keychain; it is checked
            // there, on its next launch, and it fails closed.
            return
                "This reaches the device on its next sync. If there is no passcode on it, it will ask for one before it opens anybody's player."
        }

        return role == .both
            ? "A shared device. Leaving the grown-up section brings it back to this child, so a review here does not leave the iPad sitting in somebody else's sandbox."
            : "A child's own device. It opens straight into their player."
    }

    // MARK: - Removed

    /// **Kept on the screen rather than taken off it**, because a revocation is a
    /// tombstone and the row is what the revoked device reads about itself — see
    /// ``FamilyStore/DeviceRecord/revokedAt``. A parent who cannot see it has no
    /// way to undo a mistake, and the device it concerns is showing a dead end.
    private var revokedSection: some View {
        Section {
            ForEach(devices.filter(\.isRevoked), id: \.id) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.label)
                        Text("Removed \(relative(device.revokedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Let back in") {
                        session.touchAdmin()
                        session.restore(device)
                        reload()
                    }
                    .font(.callout)
                }
            }
        } header: {
            Text("Removed")
        } footer: {
            Text(
                "A removed device opens nothing and says so. Letting it back in is the only way — it cannot undo this for itself, however many times it is relaunched."
            )
        }
    }

    // MARK: -

    /// Writes through the session so ``FamilySync/Enrollment`` gets a say: this
    /// device re-resolves its own binding at once, another device is a household
    /// write that reaches it on the next sync.
    private func roleBinding(of device: DeviceRecord) -> Binding<EnrollmentRole> {
        Binding(
            get: { EnrollmentRole(rawValue: device.roleRaw) ?? .parentOnly },
            set: { newValue in
                session.touchAdmin()
                if let refusal = session.setRole(newValue, on: device) {
                    trouble = refusal.explanation
                }
                reload()
            }
        )
    }

    private func description(of role: EnrollmentRole) -> String {
        switch role {
        case .parentOnly: "A grown-up's device"
        case .kidOnly: "A child's own device"
        case .both: "Shared"
        }
    }

    private func boundKid(of device: DeviceRecord) -> Binding<UUID?> {
        Binding(
            get: { device.boundKidID },
            set: { newValue in
                session.touchAdmin()
                if let refusal = session.rebind(device, to: newValue) {
                    trouble = refusal.explanation
                }
                reload()
            }
        )
    }

    private func reload() {
        devices = session.enrolledDevices()
    }

    private func lastSeen(_ device: DeviceRecord) -> String {
        device.lastSeenAt == .distantPast
            ? "Never" : device.lastSeenAt.formatted(.relative(presentation: .named))
    }

    private func relative(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "at some point" }
        return date.formatted(.relative(presentation: .named))
    }

    private func glyph(for device: DeviceRecord) -> String {
        switch device.platform {
        case .phone: "iphone"
        case .pad: "ipad"
        case .mac: "laptopcomputer"
        // A raw value this build does not know. The row keeps its name and loses an
        // icon, which is exactly what `DeviceRecord.platform` documents as the
        // caller's choice here.
        case nil: "questionmark.square.dashed"
        }
    }
}

// MARK: -

/// Renaming exists because the identifier occasionally churns, so a roster with
/// two "Sam's iPad" rows has to be something a person can tidy.
private struct RenameDeviceSheet: View {
    let device: DeviceRecord
    let save: (String) -> Void

    @State private var draft: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("What you call this device", text: $draft)
            }
            .navigationTitle("Rename")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(draft)
                        dismiss()
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { draft = device.label }
    }
}
