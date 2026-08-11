import CloudKit
import FamilySync
import Foundation

/// **A throwaway probe. Delete it once its answers are written down.**
///
/// What it is for: `existingShare(for:)` is new and every caller in
/// `CloudKitSharing` now depends on it — `participants`, `reconcileGrants`,
/// `removeParticipant`. If it returns `nil` for a share that does exist, the
/// roster reads empty and the second grant step silently does nothing, and both
/// of those look exactly like "nobody has joined yet", which is also the expected
/// state. No test can catch that: none of them carry an entitlement.
///
/// It cannot touch the question that matters most. Whether a *participant* can
/// write to a zone-wide shared zone needs two accounts and two devices, and a
/// simulator has one account. This is the owner half only.
///
/// **Deliberately not pointed at the household zone.** The `.child` role's anchor
/// is `kid-<uuid>-work`, so the whole run happens in zones named after a kid UUID
/// that does not exist, and it deletes them at the end. Putting a `CKShare` on the
/// real `household` zone would leave this account's household genuinely shared as
/// a side effect of a diagnostic.
///
/// Debug builds use the **development** CloudKit environment, which is a separate
/// database from production — so nothing here goes near the one-way door that the
/// first production schema promotion is.
enum SharingProbe {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-probeSharing")
    }

    /// Obviously not a real child, and stable so a second run reuses the zones
    /// rather than littering a new pair.
    private static let fakeKid = UUID(uuidString: "00000000-0000-4000-8000-00000000fa4e")!

    private static let containerID = "iCloud.com.thegoldenmule.auralsanbox"

    /// Runs, then kills the process.
    ///
    /// The exit is not tidiness: `simctl launch --console-pty` stays attached for
    /// as long as the app lives, and a SwiftUI app lives forever — so without this
    /// the run never returns and the output never flushes.
    static func runAndExit() async {
        await run()
        exit(0)
    }

    static func run() async {
        say("── sharing probe ──")

        let container = CKContainer(identifier: containerID)
        let sharing = CloudKitSharing(containerIdentifier: containerID)

        // 1. Is there an account at all? Every answer below is meaningless
        //    without one, and "not signed in" is the likeliest reason for a run
        //    that reports nothing rather than a bug in the code under test.
        guard await accountIsUsable(container) else {
            say("STOP: no usable iCloud account in this simulator. Sign in and re-run.")
            return
        }

        // 2. Which side does this device think it is on? Expect `.owner` — a
        //    simulator that has accepted nothing has no zones in its shared
        //    database, and only the shared database is evidence.
        do {
            let side = try await sharing.side()
            say("side() = \(side)  [expect owner]")
        } catch {
            say("side() FAILED: \(error)")
            return
        }

        // 3. The regression this probe exists for, and it has to be asked BEFORE
        //    anything creates a share. `participants()` used to call `ensureShare`,
        //    so simply asking who is on this family minted a share on the
        //    household zone. Empty here means reading no longer publishes.
        await report("participants() before any invitation") {
            let people = try await sharing.participants()
            return "\(people.count) participant(s)  [expect 0, and NO household share created]"
        }
        let householdSharedEarly = await zoneWideShareExists(container, .household)
        say("   household share exists = \(householdSharedEarly)  [expect false]")

        // 4. Issue a child invitation. This creates every zone in `SharePlan` and
        //    a share on each zone the role is granted — two, both kid zones.
        var firstURL: URL?
        await report("invitation(for: .child)") {
            let url = try await sharing.invitation(for: .child(fakeKid), kids: [fakeKid])
            firstURL = url
            // The token is a credential. Shape only.
            return "got a URL  host=\(url.host() ?? "nil") pathDepth=\(url.pathComponents.count)"
        }

        // 5. Did it land where `SharePlan` says? Read the zone-wide share record
        //    directly, by the same record ID `existingShare` builds — so this is
        //    that logic checked against the server rather than against itself.
        say("   kidWork share exists = \(await zoneWideShareExists(container, .kidWork(fakeKid)))  [expect true]")
        say("   kidPolicy share exists = \(await zoneWideShareExists(container, .kidPolicy(fakeKid)))  [expect true]")
        say(
            "   household share exists = \(await zoneWideShareExists(container, .household))  [expect FALSE — a child is never given the household]"
        )

        // 6. The read-back path. A second invitation must find the share the
        //    first one made rather than making another; an identical URL is the
        //    observable form of that, and a *different* one would mean the
        //    lookup misses and every read in the app misses with it.
        await report("invitation(for: .child) again") {
            let again = try await sharing.invitation(for: .child(fakeKid), kids: [fakeKid])
            let same = again == firstURL
            return "same URL as the first = \(same)  [expect true — found, not re-created]"
        }

        // 7. The new guard. No invitation has been issued for the co-parent role,
        //    so there is no household anchor share, so there is nothing
        //    outstanding — and asking must not create one. This is what makes it
        //    safe to run reconciliation on every launch.
        await report("reconcileGrants(.coParent) with no co-parent invitation") {
            let changed = try await sharing.reconcileGrants(for: .coParent, kids: [fakeKid])
            return "\(changed) change(s)  [expect 0]"
        }
        say(
            "   household share exists = \(await zoneWideShareExists(container, .household))  [expect STILL false]"
        )

        // 8. And with an anchor but nobody who has accepted.
        await report("reconcileGrants(.child) with no participants") {
            let changed = try await sharing.reconcileGrants(for: .child(fakeKid), kids: [fakeKid])
            return "\(changed) change(s)  [expect 0]"
        }

        await cleanUp(container)
        say("── end ──")
    }

    // MARK: -

    private static func accountIsUsable(_ container: CKContainer) async -> Bool {
        let status = try? await container.accountStatus()
        say("accountStatus = \(status.map(String.init(describing:)) ?? "unreadable")")
        guard status == .available else { return false }
        let id = try? await container.userRecordID()
        say("userRecordID = \(id == nil ? "nil" : "present")")
        return id != nil
    }

    /// Whether a zone carries a zone-wide share, read raw.
    ///
    /// Built from `CKRecordNameZoneWideShare` and `HouseholdSide.zoneID(for:)` —
    /// the same two pieces `existingShare` uses — so a disagreement between this
    /// and the app's own answer localises the bug to that method.
    private static func zoneWideShareExists(_ container: CKContainer, _ zone: FamilyZone) async
        -> Bool
    {
        let id = CKRecord.ID(
            recordName: CKRecordNameZoneWideShare,
            zoneID: HouseholdSide.owner.zoneID(for: zone)
        )
        let record = try? await container.privateCloudDatabase.record(for: id)
        return record as? CKShare != nil
    }

    /// Removes the zones this probe made.
    ///
    /// **The two kid zones only.** Deleting a record zone deletes its share with
    /// it, so this leaves nothing shared behind. `household` is left alone: it is
    /// the real one, `SyncEngineHost.start` creates it on every launch anyway, and
    /// this probe never put a share on it.
    private static func cleanUp(_ container: CKContainer) async {
        for zone in [FamilyZone.kidWork(fakeKid), .kidPolicy(fakeKid)] {
            let id = HouseholdSide.owner.zoneID(for: zone)
            do {
                _ = try await container.privateCloudDatabase.deleteRecordZone(withID: id)
                say("cleaned up \(id.zoneName)")
            } catch {
                say("CLEANUP FAILED for \(id.zoneName): \(error) — delete it by hand")
            }
        }
    }

    private static func report(_ what: String, _ body: () async throws -> String) async {
        do {
            say("\(what): \(try await body())")
        } catch {
            say("\(what) FAILED: \(error)")
        }
    }

    /// `print`, named so the probe reads as what it is. Run with
    /// `simctl launch --console-pty` — plain `--console` swallows stdout.
    private static func say(_ message: String) {
        print("[probe] \(message)")
    }
}
