import CloudKit
import FamilyStore
import FamilySync
import SwiftUI

/// The CloudKit probes, run from inside the app.
///
/// **This is a throwaway, and it is here rather than in a target of its own for
/// one reason: entitlements.** A probe needs the container, and the container is
/// granted to this bundle identifier — a second target would need its own App ID
/// and its own capability, which is more paperwork than the thing being tested.
/// It lives behind the gate, it is the only screen in the app that touches
/// CloudKit, and it is meant to be deleted once the answers are written down.
///
/// **What it can and cannot settle.** Everything here runs against a real
/// container, so a pass is real. But a simulator has one Apple Account, so the
/// probe that actually decides the architecture — *can a share participant
/// write?* — cannot be answered from one machine no matter what it reports. The
/// probes are ordered so that is obvious rather than buried.
enum CloudKitProbe {
    struct Line: Identifiable, Sendable {
        let id = UUID()
        let text: String
        let mark: Mark
    }

    enum Mark: Sendable {
        case pass, fail, info, needsHardware

        var symbol: String {
            switch self {
            case .pass: "✓"
            case .fail: "✗"
            case .info: "·"
            case .needsHardware: "▲"
            }
        }

        var color: Color {
            switch self {
            case .pass: .green
            case .fail: .red
            case .info: .secondary
            case .needsHardware: .orange
            }
        }
    }


    /// Runs the probes with no UI and prints each line.
    ///
    /// **The point is that the result is capturable.** Driving a gate and a tap
    /// from a script is not worth building; a launch argument and
    /// `simctl launch --console` is. Identical code path to the screen, because
    /// both call `run()` — so the headless answer cannot drift from the one a
    /// person sees.
    static func runHeadless() async {
        let lines = await run()
        print("=== CLOUDKIT PROBE ===")
        for line in lines { print("\(line.mark.symbol) \(line.text)") }
        print("=== END PROBE ===")
    }

    // MARK: -

    static func run() async -> [Line] {
        var log: [Line] = []
        func say(_ text: String, _ mark: Mark = .info) {
            log.append(Line(text: text, mark: mark))
        }

        let container = CKContainer(identifier: "iCloud.com.thegoldenmule.auralsanbox")

        // Probe 0 — is there an account at all? Everything below is meaningless
        // without one, and `.restricted` is what parental controls produce, so
        // it is worth naming rather than lumping in with "not signed in".
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available: say("Account available", .pass)
            case .noAccount: say("No iCloud account — sign the simulator in", .fail)
            case .restricted: say("Account restricted (this is what parental controls produce)", .fail)
            case .couldNotDetermine: say("Account status could not be determined", .fail)
            case .temporarilyUnavailable: say("Account temporarily unavailable", .fail)
            @unknown default: say("Account status unrecognised", .fail)
            }
            guard status == .available else { return log }
        } catch {
            say("accountStatus threw: \(error.localizedDescription)", .fail)
            return log
        }

        let db = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: "probe")

        do {
            _ = try await db.save(zone)
            say("Custom zone created", .pass)
        } catch {
            say("Could not create a custom zone: \(readable(error))", .fail)
            return log
        }

        // Probe C — does `encryptedValues` carry Data?
        //
        // The activity payload and the passcode verifier both depend on it, and
        // the encryption disposition is the hardest one-way door in the design:
        // a promoted schema is additive-only and a field cannot move between
        // clear and encrypted afterwards.
        let payload = Data((0..<64).map { UInt8($0 & 0xFF) })
        let recordID = CKRecord.ID(recordName: "probe-encrypted", zoneID: zone.zoneID)
        let record = CKRecord(recordType: "Probe", recordID: recordID)
        record.encryptedValues["payload"] = payload
        record.encryptedValues["text"] = "a child's search term"
        record["clear"] = "not a secret"

        do {
            _ = try await db.save(record)
            say("Saved a record with encrypted values", .pass)
        } catch {
            say("Could not save encrypted values: \(readable(error))", .fail)
            return log
        }

        do {
            let fetched = try await db.record(for: recordID)
            let backData = fetched.encryptedValues["payload"] as? Data
            let backText = fetched.encryptedValues["text"] as? String

            if backData == payload {
                say("encryptedValues carries Data — round-tripped 64 bytes", .pass)
            } else {
                say("encryptedValues did NOT return the Data (\(backData?.count ?? -1) bytes)", .fail)
            }
            if backText == "a child's search term" {
                say("encryptedValues carries String", .pass)
            } else {
                say("encryptedValues did NOT return the String", .fail)
            }
            if fetched["clear"] as? String == "not a secret" {
                say("Clear values unaffected", .pass)
            }
        } catch {
            say("Could not read the record back: \(readable(error))", .fail)
        }

        // Probe A, owner half — can a zone-wide share even be created and saved?
        //
        // The half a single machine can answer. The half it cannot is the one
        // that decides the architecture: whether a *participant* can write to
        // the shared zone. That needs a second Apple Account on a second
        // device, and no amount of running this here will produce one.
        do {
            let share = CKShare(recordZoneID: zone.zoneID)
            share[CKShare.SystemFieldKey.title] = "Probe" as CKRecordValue
            _ = try await db.save(share)
            say("Zone-wide CKShare created and saved", .pass)
            say("Participant WRITE is still unproven — needs a second account on a second device", .needsHardware)
        } catch {
            say("Zone-wide share refused: \(readable(error))", .fail)
            say("If this failed, the whole sharing topology is in question", .needsHardware)
        }

        // Probe B is not attempted. An under-13 account cannot be signed into a
        // simulator in any way that means anything, and Screen Time — which is
        // what produces `.restricted` — cannot be tested there at all.
        say("Under-13 account behaviour: not testable here, needs a real child account", .needsHardware)

        do {
            _ = try await db.deleteRecordZone(withID: zone.zoneID)
            say("Cleaned up the probe zone", .info)
        } catch {
            say("Could not delete the probe zone: \(readable(error))", .info)
        }

        return log
    }

    /// CloudKit errors are far more useful with their code than with their
    /// localised description, which is usually "an error occurred".
    private static func readable(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        return "CKError \(ck.errorCode) — \(ck.localizedDescription)"
    }
}

/// The probe screen. Behind the gate, and the only screen in the app that
/// touches CloudKit.
struct CloudKitProbeView: View {
    @State private var log: [CloudKitProbe.Line] = []
    @State private var running = false

    var body: some View {
        List {

            Section {
                Button(running ? "Running…" : "Run the probes") {
                    Task { running = true; log = await CloudKitProbe.run(); running = false }
                }
                .disabled(running)
            } footer: {
                Text(
                    "Writes and deletes a handful of records in a zone called `probe`. "
                        + "Nothing else in the app touches CloudKit."
                )
            }

            if !log.isEmpty {
                Section("Results") {
                    ForEach(log) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.mark.symbol).foregroundStyle(line.mark.color).monospaced()
                            Text(line.text).font(.callout)
                        }
                    }
                }
            }
        }
        .navigationTitle("CloudKit probes")
    }
}
