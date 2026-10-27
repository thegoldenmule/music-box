# Accounts, Devices and Sync

**Status:** restating

## Sections
### Motivation
MusicKit plays under whichever Apple Account is signed into the device.

We need to handle two cases: one in which the child and parent share a device and therefore iCloud account, and one in which the child has their own iCloud account in an Apple Family.

### Overview
This section descrives who is who, which device is which, and how settings reach the kid.

First release: one device with no sync. A parent configures the kid's iPad directly and the data stays there. That removes a category of work and of legal exposure.

For V2, we want to support having one or more child accounts under Family Sharing.

Device role is chosen during setup, not inferred.

Sync comes later over CloudKit, but the schema has to be shaped for it before there is data in the wild.

### Data model & types
```swift
/// Chosen during setup. Defaulting to .both puts the admin one tap from the kid.
enum DeviceRole {
    case parentOnly     // no player at all
    case kidOnly        // launches into the player; admin behind the gate
    case both           // shared iPad; same as kidOnly on launch
}

/// Asked, not detected — there is no public API for Family Sharing membership.
enum AccountSetup {
    /// Kid uses the parent's account. Works immediately; the kid's plays land in
    /// the parent's history and recommendations.
    case shared
    /// Kid has their own account under Family Sharing with an Apple Music Family
    /// plan. Separate library, history and recommendations.
    /// An under-13 account cannot have an Apple Music profile.
    case childAccount
}

struct DeviceConfiguration {
    let role: DeviceRole
    let accountSetup: AccountSetup
    var activeKidID: UUID?      // nil on parentOnly; required otherwise
}

struct Family: Identifiable {
    let id: UUID                // stable from v1 so a CloudKit record can adopt it
    var modifiedAt: Date
    var kids: [Kid]
}

struct ServiceState {
    let authorization: AuthorizationStatus
    let subscription: SubscriptionState?    // nil until the first read completes
}
```

### Algorithm
**First run.**

```text
1. request MusicKit authorization; denied or restricted -> explain and stop
2. read the subscription; cannot play catalog content -> say so, and offer
   signup only behind the gate
3. ASK for the device role. Never infer it, never default to .both
4. ASK which account setup this is, and say what each means:
     shared       -> the kid's listening shows up in your recommendations
     childAccount -> the kid gets their own history
5. set the admin passcode
6. create the first kid; kidOnly and both require an activeKidID before launch
```

**Launch.**

```text
1. read the configuration
2. parentOnly -> the gate. kidOnly or both -> the active kid's player, no chooser
3. re-read authorization; it can be revoked in Settings between launches
4. subscribe to subscription updates for the session
```

**Switching the active kid.**

```text
1. require the gate
2. set activeKidID
3. tear down the engine and the queue, so one kid cannot inherit another's policy
```

### Invariants & limits
- Device role is chosen explicitly during setup and never defaulted.
- A `kidOnly` or `both` device always has an `activeKidID` before the player renders.
- A `parentOnly` device has no player surface.
- Switching the active kid requires the gate and rebuilds the engine and queue.
- One active kid per device. Multiple kid profiles, never multiple simultaneous sessions.
- No data leaves the device in this version. No sync, no server, no account linkage.
- Every persisted record carries a stable UUID and a `modifiedAt`, whether or not anything reads them.
- Nothing assumes identifiers are locally sequential.
- Authorization is re-read on every launch.
- Subscription state is observed for the session, not read once.
- Nothing about subscriptions or purchases appears on the kid's side of the gate.

### Failure & concurrency semantics
**No subscription.** Nothing plays, and the app says so rather than showing an empty catalog. A signup offer appears only behind the gate; the MusicKit terms forbid monetising access to the service, so this is a hand-off, not a paywall.

**Subscription lapses mid-session.** Playback stops. Lists and reports stay intact — losing curation because a payment failed would be inexcusable.

**Authorization revoked in Settings.** Detected on the next launch or read. Catalog features fail, local data is untouched, and re-granting restores everything.

**A child account behaving differently.** The one genuinely unknown case. Child accounts have documented quirks, and there may be more. Every claim about that configuration is an assumption until it has been run end to end on a real one.

**A parent's new phone.** Local data lives on the kid's device, so nothing is lost. That inverts once sync exists.

**Concurrency.** One device, one writer, one active kid. Nothing to reconcile. Sync breaks that invariant: two parents editing one kid's list has no answer in this model, and last-write-wins over a whole list would discard someone's work.

### Data dependencies
**Authorization** — a system prompt once, then re-read every launch, since it can be revoked in Settings.

**Subscription state** — read after authorization, then observed. There is an ordered window at launch where the app knows it is authorized but not yet whether it can play. The player must not be offered in that window.

**Device configuration** — local, read before the first screen. Missing means setup, which is a state rather than a failure.

**The active kid's policy** — local, read after configuration.

**Which Apple Account is signed in** — owned by the system, changeable outside our app, and we are not notified. A parent could sign the device into a different account between sessions and the app would carry on against someone else's music. Nothing detects this today; it is a known gap.

**Family Sharing membership** — no public API, which is why `AccountSetup` is asked rather than detected.

### Migration & existing data
**Nothing to migrate.** No installs, no configurations, no lists.

The point of this section is the migration that has not happened yet: this version ships without sync, and sync is the change that will hurt. Retrofitting CloudKit onto a schema that never expected it is painful in avoidable ways, so v1 pays a small cost now.

All of it free today:

- Stable UUIDs on every record, generated at creation.
- `modifiedAt` on everything, written on every change. Conflict resolution without it is guesswork.
- No logic that depends on ordering by identifier.
- The family as an explicit record with its own id, since a `CKShare` needs something to hang from.

Conflict resolution is deliberately not designed yet, because it cannot be without knowing the sharing model. What is certain is that sync ends the single-writer invariant, and last-write-wins over a whole list would destroy curation.

The CloudKit path needs prototyping in a throwaway project first. Sharing requires a custom record zone and a share-acceptance flow, and the SwiftData integration is reportedly rough.

### Staged plan
**Stage 1 — one device, no sync.**

- Ships: setup asking for device role and account setup, authorization and subscription handling, one family stored locally, stable UUIDs and timestamps.
- Does not: sync, multi-device, any network storage of ours.
- Exit test: a parent configures a kid on an iPad, the kid plays under the right policy, and replacing the parent's phone loses nothing.

**Stage 2 — the child-account test.**

- Ships: nothing new. This replaces an assumption with a fact.
- Does not: proceed to sync until it passes.
- Exit test: authorization, subscription check, search, playback and logging exercised end to end on a real under-13 child account on hardware, with every deviation written down.

**Stage 3 — the sync prototype.**

- Ships: a throwaway project proving CloudKit sharing between two accounts, with a custom zone and a real share-acceptance flow.
- Does not: touch the shipping app.
- Exit test: a record created on one account appears on the other, and the time it took is written down.

**Stage 4 — sync, with a conflict answer.**

- Ships: parent-device editing of a kid's configuration, with a resolution strategy that cannot silently discard a list.
- Does not: ship on last-write-wins over whole lists.
- Exit test: two parents edit the same list from two devices while offline, both reconnect, and neither one's additions are lost.

### Sync: the decision, and why it is not SwiftData's
The sections above were written when v1 was one device with no sync, and they still describe that correctly. This one and the four after it are the amendment: multiple adults managing kid profiles, and kid profiles tied to accounts and devices.

**The decision: do not mirror the store. Hand-roll the transport.**

`FamilyStore.container()` stays exactly as it is — no `cloudKitDatabase`, no attached container, ever. A new `Packages/FamilySync` owns the `CKRecord` mapping and runs two `CKSyncEngine` instances (iOS 17 / macOS 14 — exactly the floor). SwiftData stays the authority; CloudKit becomes a transport over it.

Three architectures were designed independently against these specs and judged on three separate lenses — the project's safety invariants, one-maintainer feasibility, and irreversibility. All three judges ranked this one first, and converged on the same property: **it is the only design where the store the player and the logger write to is never mirrored.** That matters more here than it would elsewhere, because `swift test` plus two `xcodebuild build` invocations is the entire verification budget available off-device, and this design puts the safety-critical merge in pure value types that `swift test` can exhaust.

Four consequences follow, each decisive against a specific alternative:

- **No local-to-mirrored migration, ever.** Flipping an existing local SwiftData store to a mirrored one is a two-container fetch-and-copy with a reported data-loss mode. That migration never arises if the container is never attached — and this store holds a child's playlists.
- **We own the record mapping**, which is the only route to content-addressed record names. Every upsert in the store today is a local-read dedup — correct under one writer, wrong under two. Content addressing makes the duplicate class impossible on the server rather than needing a cleanup sweep.
- **We own conflict resolution**, which the Stage 4 exit test demands and which no mirroring layer will give per-field.
- **We can encrypt free-text fields** (`CKRecord.encryptedValues`), so a child's search terms are unreadable to Apple's servers. This is the most substantive improvement to the COPPA position available, and it exists only because we own the mapping.

`zoneNote`**'s open question is closed on the participant side.** SwiftData's `CloudKitDatabase` has exactly `automatic | private(_:) | none`. There is no shared-database store scope, so a second parent's device could never read the share regardless of what the owner side can do. The owner-side half — whether a zone-wide `CKShare` can be hand-attached to the zone SwiftData manages — stays unverified and is now moot, because nothing is mirrored.

**Two corrections to the obvious shape of this design**, both of which make it cheaper than it first looks:

1. **One **`ModelContainer`**, not two.** Nothing is mirrored, so "what syncs" is a _declaration plus a mapper_, not a store boundary. Every `@Model` relationship and all of `Kid`'s cascade rules survive untouched. `FamilyStore` declares `syncedModels` and `neverSyncs`, and a reflection test fails if any member of `schema` is in neither — so "no mapper" is a declaration rather than an omission bug.
2. **No **`CKRecord.Reference`** anywhere; every cross-record link is a UUID string.** This is what makes severing `Kid.family` unnecessary: the relationship stays live in SwiftData and the mapper encodes `family?.id` as a plain field, so a record in a kid zone can point at the household `Family` with no cross-zone reference.

### The gap that has to be closed first: nothing tracks what changed
A hand-rolled engine over an unmirrored store must be told, durably, which rows to push. This repo has no way to know.

- A repo-wide grep for `HistoryDescriptor`, `didSave`, `willSave`, `NotificationCenter` and `RemoteChange` over `Packages` and `Apps` returns **zero hits**.
- SwiftData History is **iOS 18**, one major version above the declared floor — all five `Package.swift` files say `platforms: [.iOS(.v17), .macOS(.v14)]`.

So every mutation must enqueue itself into a durable outbox at the call site, and a crash between `context.save()` and the enqueue loses the change with nothing able to detect it. That means a pending-change table, an enqueue at every write in `FamilyStore`, and a reconciliation scan for the crash window. **It is a stage-sized body of work and a precondition for the mapper, not a detail inside it.**

The same gap has a second half: **tombstones for real deletes.** A deleted SwiftData row leaves nothing to enumerate, so the deletion can never be exported and a co-parent's device keeps the row forever. The real deletes on models that would sync are `CloudKitLibraryProvider.swift:107` (favorite), `:185` (playlist entry), `:204` (playlist); `Session.swift:346` (kid), `:394` (grown-up); and `Kid.swift:561`, which is everything `deleteHistory` reaches.

### Identity and binding
`DeviceRole`, `AccountSetup` and `DeviceConfiguration` are specified in the sections above and **appear in no Swift file** — a repo-wide grep returns two hits, both prose in `FamilyStore.zoneNote`. The active kid is `family.kids.first` on an unordered relationship (`Session.swift:238` and `:349`) and the choice is never persisted, so once that relationship is CloudKit-backed a seven-year-old's iPad can open into his twelve-year-old sister's `reportOnly` sandbox and file every play under her name.

**State the mechanism honestly: the device is the key; the account is a conditional upgrade.** `CKContainer.userRecordID` needs a live iCloud account, and `.restricted` — which Apple documents as exactly what parental controls produce — is a plausible steady state on precisely the kid device the binding is for. Whether an under-13 account can be a CloudKit share participant at all is unverified. If it cannot, every kid device runs on a parent's account and `Kid.boundAccountRecordName` is one unused column; the design is shaped so that outcome changes one enrolment screen and nothing else.

The rules, as invariants:

1. **A device mints its own identity and nothing else may name it.** A UUID in the Keychain, non-synchronizable, `AfterFirstUnlockThisDeviceOnly`. Never `identifierForVendor` — it does not exist on native macOS (`SUPPORTS_MACCATALYST = NO`), and Apple documents it as churning on Xcode and ad-hoc installs. An empty read registers a **new** device and never adopts an existing row: the failure mode of guessing is one child's iPad silently inheriting another's binding.
2. **Identity syncs; state does not.** `DeviceRecord` carries identity, label, role, binding and audit — every field the same fact from either parent's phone. It carries nothing a device needs in order to _run_. The test for any future field: _would two devices legitimately hold different values?_ If yes it is state and stays local, beside `DeviceLibraryState` and `ActingGrownUp`.
3. **An account binding beats a device binding**, because the child carries it across hardware.
4. **A device binding governs only under the account it was enrolled with.**
5. **A mismatch locks; it never switches and never falls back.** No nearest-kid, no first-kid. Opening a different child puts a different policy level in force, shows another child's library, and files every play under the wrong name — three failures that all look like the app working.
6. **No account is not a mismatch.** `noAccount`, `restricted` and `temporarilyUnavailable` are three platform states and one binding state: no opinion. The device binding governs, the app runs on last-imported data, nothing is deleted, and the kid player never mentions it.
7. **A kid binding requires a gate on that device.** Enrollment refuses to set `boundKidID` until a passcode exists locally.
8. `isPasscodeSet`** means "this family has a gate or this device has one", and it fails closed.** _Enter_ on a device holding family data with no local item; _Choose_ only when no epoch exists anywhere. A Keychain error is a third state, never "absent".
9. **The account is compared at every launch, not only on notification.** `CKAccountChanged` does not fire for a switch made while the app was quit, which is the case that actually happens. This is the answer to the known gap the Data dependencies section admits.
10. **Account identity is a hint, never an authorization and never a key.** It does not open the gate, does not widen reach, and is never pointed at by a row. It is _allowed to be wrong_ — dev and prod CloudKit are separate databases and survival across reinstall is undocumented — so every path that reads it has a working answer when it is stale.
11. `family.kids.first`** must not survive.** Both call sites go.
12. **Exactly one **`Family`** exists and its id is discovered, never invented.** _"CloudKit was unreachable"_ is not confirmation that there is no zone to join.
13. **The assignment syncs; the selection does not.** `DeviceRecord.boundKidID` is the household fact, set behind the gate. The active selection is the device fact. On a shared iPad, **leaving admin restores the assignment** — a review session must not leave the family iPad sitting in one child's sandbox for another.
14. **Revocation is a tombstone, and it is the one removal in this store that must not delete.** A deleted row is re-created by the device on its next launch, so a delete silently un-revokes itself. Everywhere else in this store, detaching without deleting is the bug; here it is the requirement, and the comment must say which is which.

**Zone topology.** One `household` zone (Family, GrownUp, DeviceRecord, PasscodeEpochRecord, ConsentRecord); and per kid a **pair** — `kid-<uuid>-policy` with the child at `.readOnly`, and `kid-<uuid>-work` with the child at `.readWrite`. The split is not optional: CloudKit permissions are per-zone, not per record type, so without it a child's own account can write the `PolicyEntryRecord`s that decide their own reach.

**Two corrections to that topology, both found by checking it against the code:**

- `SuggestionRecord`** cannot sit in the read-only zone.** `SuggestionRecord.dismiss()` is a kid-side write, and its own comment says why: _"this one changes what the child can reach, and _`modifiedAt`_ is what a sync merge compares"_ (`SuggestionRecords.swift:202-213`). Dismissal is what withdraws the allow (`PolicyBuilding.swift:99-105`). Read-only means the server rejects a child tapping "no thanks" and the allow stays permanently live. Either suggestions move to the work zone, or dismissal splits into a separate kid-writable record.
- **The passcode epoch must not be replicated into a kid zone.** Handing a brute-forceable PIN verifier to the device most likely to be lost or handed on is the trade running the wrong way, and it contradicts rule 2.

### What the schema must pay for now
Nothing has shipped, so each of these is an afternoon today and a migration across two Apple Accounts' live data after the first production CloudKit schema promotion — which is additive-only forever. This is the highest-value part of the amendment.

**Fixes to existing records**

- `mode`** and **`unratedBehavior`** become an append-only **`SandboxSettingRecord` `{ id, kidID, key, rawValue, decidedAt, decidedByAccount }`. Effective value is the latest `decidedAt`, with concurrent rows inside the sync window resolving to the **narrower** setting (`allowOnly` < `denyPlusAuto` < `reportOnly`; `.block` beats `.allow`). `Kid` keeps a denormalised copy as a cache that is never the authority. _Why:_ these two fields decide what a child can reach and they sit on one record beside `name`, so a concurrent rename and a mode change resolve as whole-record last-write-wins and **the tightening vanishes with no UI trace**. As decision rows, a rename can never contend with a mode change, and the admin can say "You set Level 1 at 16:02; Dad set Level 2 at 16:05."
- **Every enum stored as a raw **`String`** with a nil-returning read and a named failure policy** — `mode` → `allowOnly`, `unratedBehavior` → `.block`. These are the only two enums in the store without a defensive read, and the two most safety-critical; five others already do it properly.
- `assertedAt`** / **`retractedAt`** on **`PolicyEntryRecord`, live iff `assertedAt > retractedAt`, every read filtering, removal stamping and never detaching. Inside a 120-second skew window a `.deny` resolves live and an `.allow` resolves retracted — the same fail-closed asymmetry as `UnratedBehavior.block`, one level up. _This is the exit-test mechanism:_ two parents editing one list offline produce four independent field changes on four rows, nothing is co-written, and every device computes the same live set with no arbitration.
- `SuggestionRecord`** gets a fresh **`id`** and a separate **`sourcePlaylistID` — today the initializer overwrites its own identity with a caller-supplied playlist UUID (`SuggestionRecords.swift:112-123`), so two parents suggesting the same source playlist produce two records with one logical key.
- **Ordering keys that survive concurrent insertion** — a lexicographic rank string, or sparse integers sorted `(position, id)`. Delete `renumber()`, whose own comment says gaps are not a supported state and which runs only on the editing device.
- `GrownUp.createdAt`**, **`.rosterRank`**, **`.accountRecordName` — CloudKit does not preserve to-many ordering, and `GrownUp` is the one model that cannot fall back to `modifiedAt` because a rename moves it. `accountRecordName` can **only** be captured at share acceptance, so adding it later means re-inviting every adult who already joined.
- `Kid.sortIndex`** and **`Kid.boundAccountRecordName` — putting the account binding as a column on the existing `Kid`, rather than modelling a second kid per account, makes a child getting their own Apple ID at nine a one-field write instead of a data migration.
- `@Attribute(.externalStorage)`** on **`WeeklySummaryRecord.payload` — an unbounded opaque `Data` column against a 1 MB record ceiling. Nothing writes this table today, so it is free right now.
- `originatingDeviceID`** on the four event tables and on **`PolicyEntryRecord` — the cheapest forensic column available, and it cannot be backfilled: the information does not exist anywhere else once the row is written.
- `exportedAt`** on the four event tables** — the watermark that makes packing resumable and stops the retention sweep deleting a row nothing has carried yet.

**New records**

- `DeviceRecord` — see Identity and binding. Revocation is a tombstone.
- `PasscodeEpochRecord` `{ id, epoch, salt, verifier, setByGrownUpID, setAt, modifiedAt }` in the household zone. Rotation by writing epoch n+1 is the first revocation path this app has ever had: `PasscodeStore.clear()` has no caller anywhere.
- `HistoryClearRecord` `{ kidID, clearedThrough, issuedAt, issuedBy }` plus a device-local watermark. Clearing history is currently an _absence_ that has to win a race: a device offline for a week imports the deletions and then exports the rows it wrote while offline, and `RecentsProjector.trail(for:)` is documented as always recomputed and saves unconditionally on every launch — so the lagging device rebuilds the shelf from still-present visits and writes it back. A parent is told the data is gone while their child's home screen lists what they were doing.
- `ActivitySegmentRecord` `{ id, kidID, deviceID, dayUTC, table, index, payload, modifiedAt }` with external storage. Events are the large majority of write volume; keyed by writing device, two devices never write the same segment.
- `ConsentRecord` `{ id, grownUpID, accountRecordName, scope, kidIDs, agreedAt, appVersion }`. Guideline 5.1.4 states that a Kids-Category parental gate is generally not the same as securing parental consent to collect personal data. If review asks what consent was recorded, the answer has to be a row.
- **A durable change outbox, and tombstone rows for the six real-delete call sites.** Not optional — see the section above.

**Structural**

- `FamilyStore.syncedModels`** and **`.neverSyncs`**, exhaustive over **`schema`**,** with a reflection test. `RecentTrailRecord` and `LibraryIndexRecord` go in `neverSyncs` — a projection that syncs _and_ is recomputed per device is a conflict generator. `LibraryIndexRecord`**'s rebuild is not free:** it is `LibraryWalk`, which imports CatalogKit and therefore needs MusicKit, network, and _that_ device's Apple Music library and storefront, so a co-parent sees an empty Albums column until their phone performs a full artist walk. **And **`WeeklySummaryRecord`** must sync**, despite being a projection: it is what survives the retention sweep, so a device-local summary means the co-parent permanently loses every swept period. It is small, cold, and single-owner once the sweep has an owner.
- `Family`** gets a discovered identity, not a generated one** — a well-known record name, or a marker whose `familyID` a joining device adopts. Family and active-kid resolution move out of `Session.load` into a testable `FamilyStore` function with a deterministic sort and a lowest-UUID merge that reparents the loser's kids and grown-ups. Today the guard is `if let family = fetch().first, let kid = family.kids.first`, so **a family with zero kids also falls through** and bootstraps a second `Family` plus a kid literally named `"Kid"`.
- **A local JSON snapshot of each kid's favorites and playlists**, rewritten on mutation, held outside the store, with a restore path. Insurance against our own sync bugs, which for hand-rolled code is the likelier failure than the platform one.
- **Decide and record the encryption disposition of every free-text field** before the mapper is written: `SearchEventRecord.term`, `PlaylistRecord.name`, `SuggestionRecord.note`, `Kid.name`, every copied `displayName` and `addedByName`, the segment payloads.

### The revised staged plan
This replaces the four stages in the Staged plan section above. Ordered so the irreversible cheap things land first and the risky expensive things land behind a probe that can kill them.

**Stage 1 — fix what is already broken, and move the safety decisions somewhere testable.** Eight defects that exist today on one device with no sync, each verified at the line: `Kid.removeEntry` detaching instead of deleting (`Kid.swift:155`, where `removeSuggestion` at `:255` already has the fix); the double-family bootstrap (`Session.swift:238`); `isConfigured` swallowing a Keychain error so it cannot tell unreadable from absent (`Passcode.swift:71`); failed-attempt backoff never persisted, so force-quitting resets it; `closeAdmin()` never called on background though `AdminGate.close()`'s own doc says it is; `Kid.appendIndex` stamping `modifiedAt` against the section comment at `Kid.swift:353-359`; `RecentsProjector.isRepeat` accepting a negative interval from a skewed clock; and **the currently playing track never re-judged** — `revalidate()` guards on `status == .stopped, !hasStartedCurrent` and all three `queuedVerdict` sites concern the queued entry, so a parent denying the song their child is playing does not stop it. _Note the seam already exists:_ `Session.rebuildEngines()` (`:1913`) fires on every list and suggestion edit; only the player-side half is missing. Does not: add a column, attach a container, or introduce any identity concept.

**Stage 2 — pay the schema, and build the outbox.** The whole list above, including the change outbox and the delete tombstones. Does not: attach a container, import CloudKit, write a mapper, or move any model into a second container. Exit: `SchemaCoverageTests` failing if a model is in neither list; strictest-wins across every `SandboxMode` pair; the four-directive offline case converging identically from either arrival order; an outbox test where a simulated crash between save and enqueue is recovered by the reconciliation scan.

**Stage 3 — two probes that can kill the topology.** Blocked in wall-clock by the iCloud capability on the App ID, and MusicKit is still not enabled either, so this is the second approval stacked on one App ID and they block the same first device run. Start the paperwork the same day as Stage 1. **Probe A:** two devices, two real Apple Accounts, production CloudKit, throwaway target under `Tools/`; one custom zone with a zone-wide `CKShare(recordZoneID:)`; owner shares, participant accepts, **participant writes**, owner observes — every load-bearing flow in this design is a participant write. **Probe B:** can a real under-13 account accept a share at all, and what is `CKAccountStatus` with Content & Privacy Restrictions on and off? Run in production as well as development — separate databases, and eligibility may differ. **Probe C:** does `CKRecord.encryptedValues` carry `Data`? Exit: not runnable off-device, and saying otherwise would be worse than useless. A written result per probe with the exact `CKError` where it failed.

**Stage 4 — the pure sync core, entirely offline.** `Packages/FamilySync`: `RecordMapper` (no `CKRecord.Reference`, every record name derived from a declared natural key), `Merge` (plain value structs in, one out, no CloudKit import), segment packing, and `BindingResolver` as a pure value type with the whole precedence rule as a table — the binding decision picks _which policy is in force_, so it gets the same purity treatment `PolicyEngine` has, for the same reason. Exit: the exit test as a named case — two parents offline, A adds a deny on artist X and removes an allow on album Y, B adds an allow on album Z and removes the same allow on Y; after merge all three intended states hold, the double-remove is idempotent, and the result is byte-identical from either arrival order.

**Stage 5 — the engine host, the zones, and the share.** Blocked by Probe A and Stage 4. Two `CKSyncEngine` instances with `stateSerialization` persisted per database; the zone topology, with the suggestion-zone question resolved; invite via `ShareLink` so our process never sees an email address; acceptance via `userDidAcceptCloudKitShareWith`; the invalidation seam extended so the post-import callback rebuilds the engine _and_ immediately re-takes the verdict on the playing and queued items. Exit: `SyncEngineHost` behind a protocol seam — the same shape `CatalogSource` uses — then a device procedure, and **record the propagation delay as a distribution across foreground, background and cold launch.** The safety story needs a number, not the word "unbounded".

**Stage 6 — identity, binding, and a gate that means something on a second device.** Blocked by Probe B and Stage 5. The fourteen binding rules; `DeviceIdentity`; the launch-time account comparison; the binding cache with the asymmetry that keeps it from becoming a bypass — _it may open a profile, it may never open admin, and it may never open a kid the last synced answer did not name_; `GrownUp` claimed at acceptance using only `userRecordID.recordName`, never `nameComponents` and never `lookupInfo`; and the passcode epoch wired.

**Stage 7 — activity, retention, compaction.** Segment export driven off the `exportedAt` watermark, never on the playback path; `HistoryClearRecord` applied idempotently against a device-local watermark; and **the retention sweep with a single named owner and a lease** — a bulk mutation with no idempotence story and no owner is a sync design question, not a retention one — two-phase and ordered, the summary written and confirmed _before_ the rows it covers are deleted. `RecentsProjector.retentionFloor(for:)`** stays.** Its own doc describes a purely local hazard — a sweep below the floor leaves a trail that cannot be rebuilt, so the next bump of `RecentTrail.version` silently empties every kid's shelf months later on an upgrade. Making the trail device-local removes none of that.

**Stage 8 — consent, the reworded claim, and the one-way door.** A consent screen at share creation, behind the gate but not _the gate reused as consent_, naming the real scope. A privacy policy shipping with v1 regardless. **The reworded claim everywhere it appears, including CLAUDE.md:** not "nothing leaves the device", which stops being true at the first save, but _"no server of ours, no third-party analytics SDK, no PII to third parties, and your family's records stay in your family's own iCloud, where we cannot read them."_ Then, and only then, the first production CloudKit schema promotion — gated on a checklist, because it cannot be undone.

**Still unspecified, and worth deciding rather than discovering:** the invite lifecycle (no pending/declined/expired state, nothing the roster shows for an invited-but-unclaimed grown-up, no re-invite path); zone lifecycle after the share exists (adding a kid creates two zones and attaches them to a live share; removing one deletes them); server-enforced `.readOnly` participation for an adult, which was ruled out along with UI scoping although they are different things — it is the one honest gradation available for a grandparent or a non-custodial parent; export-queue priority, since there is no API to reorder a pending queue and a parent's deny can sit behind a child's write flood; the KDF for the passcode verifier; and seal-versus-lock on an account switch, where a lock leaves the previous family's data intact on a device that has been sold.

### What is unverified in this amendment
Stated in the sense this project uses the word: these compile, or they are documented by Apple, and neither is evidence.

- **Whether a zone-wide **`CKShare`** can be attached to a custom zone and written by a participant** — Probe A, and the design's kill condition. The proposed fallback is raw `CKModifyRecordsOperation` for the shared half, keeping the mapping, merge, topology and schema. _That fallback is asserted, not established_ — if the reported failure is server-side it is not a fallback at all.
- **Whether an under-13 Apple Account can accept a share** — Probe B. It decides whether account binding ships or is one unused column.
- **Whether **`CKRecord.encryptedValues`** carries **`Data` — Probe C. The segment payloads depend on it, and the improved COPPA position leans on it.
- **Whether a promoted field's encryption disposition is truly immutable.** The additive-only property of a promoted schema is documented; the corollary that a field's encryption disposition can never be changed, only paralleled by a new field with a different name, is a strong reading rather than something found documented. Confirm before relying on it, because the plan treats it as the hardest one-way door.
- **Whether **`userRecordID`** survives reinstall** — strongly reported, not documented. Binding rule 10 exists because of this.
- **The COPPA rewording needs a lawyer**, alongside the still-unanswered ADP 3.3.6(D) indirect-monetisation question — different blockers, same conversation. Do not write "CloudKit sync does not change our COPPA posture" as a fact. It is a position, with reasoning (no server of ours, the developer has no read access, it is the family's own storage, Apple has already verified the adult) and a named residual risk (5.1.4's trigger is the _capability_ to share a minor's personal information, which the share creates regardless of who holds the bytes).

### Correction: "nothing to migrate" no longer holds
The **Migration & existing data** section above opens _"Nothing to migrate. No installs, no configurations, no lists"_, and the staged plan in the amendment sections was written under it. That is no longer true: there is existing data, and every schema change from here has to carry it forward.

The detail, the three rules it imposes, and the three pay-now items that need custom migration stages rather than lightweight ones are in **Storage and Data Model**, under _Correction: there is existing data, and it has to migrate_. That page owns the migration slot, so the reasoning lives there rather than being copied here.

What it changes for **this** page:

- **The staged plan's ordering still holds, and gets a stronger argument.** Stage 2 was "pay the schema while it is free". It is no longer free — but it is a _lightweight_ migration now and a custom one after the CloudKit schema is promoted, so paying early still wins by more than it did.
- **Stage 2 gains a precondition** that has been met: the schema is versioned before any column is added. `FamilySchemaV1` and `FamilyMigrationPlan` are in `FamilyStore`, `container()` opens through the plan, and a store written in the pre-version shape re-opens with its household, curation and playlists intact. A store opened without a plan records no version, so the first migration would otherwise have had no `fromVersion` to name.
- **Stage 8's one-way door now has a second one in front of it.** The plan already named the first production CloudKit schema promotion as the point of no return. A shipped _local_ schema is a milder version of the same thing: reversible only by a migration, never by an edit. Both belong on the checklist.
- **The kid-profile binding work is unaffected in shape and affected in cost.** `Kid.boundAccountRecordName`, `Kid.sortIndex` and `DeviceRecord` are all additive, so they migrate lightly. `DeviceRecord` in particular has no existing rows to reconcile: every device enrols fresh, and a device with no record is a device that has not been enrolled, which is already the state the binding rules treat as unbound.

### Measured: the probes, and a correction to this amendment's premise
Run against the real CloudKit container from a simulator. Full detail and the method are in **Open Questions and Research Tasks**; this is what changes for the design above.

## The premise was wrong in a way that mattered

The amendment says _"_`FamilyStore.container()`_ stays exactly as it is — no _`cloudKitDatabase`_, no attached container, ever."_ **Omitting the parameter does not do that.** `ModelConfiguration`'s `cloudKitDatabase` defaults to `.automatic`, and `.automatic` means _on if the app is entitled_ rather than _off_.

So the store was unmirrored only because the app carried no iCloud entitlement. Adding one — which this amendment requires — flipped SwiftData into CloudKit mode by itself, and the store stopped opening at all: `NSCocoaErrorDomain 134060`, _CloudKit integration requires that all relationships be optional_, listing sixteen. `.none` is now passed explicitly.

The decision is unchanged and the reasoning for it is unchanged. What changed is that it is now enforced by the code rather than resting on an accident of provisioning — and that the accident was going to break the moment the entitlement landed, which is a thing this amendment itself was asking for.

**A second fact fell out of the same error.** CloudKit wants **to-many** relationships optional, not just their inverses. The inverses are the half already done and the half this workspace describes as finished; sixteen arrays are not. That is the price of entry if mirroring is ever reconsidered, and it is a schema change, so it is cheap now and a migration later.

## Probe C is answered, and it is a yes

`CKRecord.encryptedValues` carries `Data` — 64 bytes round-tripped, along with a `String`, with clear values on the same record unaffected. So the `ActivitySegmentRecord` payload and the `PasscodeEpochRecord` verifier can both be encrypted, the encryption disposition table can be written against something measured, and the reworded COPPA position rests on a fact rather than a hope. This retires the corresponding bullet in _What is unverified in this amendment_.

## Probe A is half answered, and the half that decides the design is the half still open

A zone-wide `CKShare(recordZoneID:)` was **created and saved** against the real container. So the owner side is not refused and the topology is not dead on arrival.

The participant side is untouched. Whether a second Apple Account can **write** to that shared zone is the reported failure mode, it is this design's kill condition, and it cannot come from one machine — a simulator has one Apple Account. It needs two devices and two accounts, and nothing short of that answers it. Everything downstream of _Stage 5_ still depends on it.

## Probe B is untouched

An under-13 account cannot be signed into a simulator in any way that means anything, and Screen Time — which is what produces `CKAccountStatus.restricted` — cannot be tested there at all. So the question of whether kid profiles can be tied to Apple IDs, or whether every kid device runs under a parent's account with the device binding as the only key, is exactly where it was.

### The invite flow is required, and Family Sharing grants nothing
From Apple's _Sharing CloudKit Data with Other iCloud Users_. It corrects an assumption recorded a day earlier and moves a listed gap into the critical path.

## Family Sharing and CloudKit sharing are unrelated systems

**There is no automatic access.** Being in the same Apple Family confers nothing on a CloudKit share. Every participant is explicitly invited and must accept — Apple's walkthrough has both accounts signed in on separate devices with a link sent between them.

This is worth stating plainly because the shorthand _"the family can see it"_ is wrong in a way that reads as right, and the whole amendment was written in that shorthand. The assumption was recorded as _"multiple Apple Accounts in a family can write to a zone-wide shared zone."_ The accurate form is narrower: **an adult who has been invited and has accepted, holding **`readWrite`**, can write.** "In a family" does no work at all.

That half is documented rather than assumed — the sample has device B editing a shared record and the change arriving in device A's private database within seconds.

## The invite flow stops being a gap and becomes the feature

_The revised staged plan_ lists the invite lifecycle under **still unspecified**: no pending, declined or expired state, nothing the roster shows for an invited-but-unclaimed grown-up, and no re-invite path. That was written as a nice-to-have. It is not. Without an invite and an acceptance there is **no second adult at all**, and therefore no multi-adult sync — which is the entire feature this amendment exists for.

What it needs, concretely: a way to send a share link (`ShareLink`, or `UICloudSharingController`), `CKSharingSupported` in `Info.plist` (present), acceptance handling, and a roster that can show somebody as invited-but-not-yet-joined. `GrownUp.accountRecordName` is already specified as captured _at acceptance_, which is consistent — it is the moment the flow produces.

## The zone-wide question is untouched by this, and the fallback got worse

Apple's article describes **hierarchy** sharing: a root record, with children pulled in through `record.parent = CKRecord.Reference(...)`. This design uses `CKShare(recordZoneID:)`, a different API, and the one with reported participant-write trouble. So the doc confirms participants can write to a shared _hierarchy_ and says nothing about the zone-wide case. Probe A's participant half is exactly where it was.

**And the stated fallback is not a substitution.** _What is unverified in this amendment_ says that if zone-wide sharing fails, the answer is to drop to another mechanism while keeping the mapping, merge, topology and schema. That is wrong for hierarchy sharing: it requires parent references, and the mapper forbids references outright — that rule is what lets a kid's rows live in a different zone from the household they point at. Hierarchy sharing pulls the reachable graph into one zone and takes the per-kid `policy`/`work` split with it, which is the split that stops a child writing their own policy entries. It is a redesign, not a fallback, and it should be priced as one.

## One safety detail for whoever builds the invite

Apple's sample sets `share.publicPermission = .readWrite`, which means **anyone holding the link can write**. For a store holding a child's search history that is the wrong default: a link forwarded once would grant write access to a stranger. Participants are added explicitly and the link is not the credential.

### A device is on one side of the share, and it has to know which
Found by reading the sharing code rather than by a test, and it was the thing to fix before either the tapped-link path or automatic sync.

**The design had no notion of whether a device owns the household or joined somebody else's.** A household is a set of zones owned by exactly one Apple Account. On the device that created them they sit in the private database and `CKCurrentUserDefaultName` names their owner. On a device that accepted an invitation the _same_ zones sit in the shared database and are owned by somebody else — a different database, a different owner name, and therefore a different `CKRecordZone.ID` for what is logically one zone.

Three consequences, all of them silent:

- `FamilyZone.id` was a property returning `ownerName: CKCurrentUserDefaultName`. Every zone ID the app built said "owned by me", so on a joined device no write could even be _addressed_ to the real zone.
- `SyncEngineHost.pushPendingChanges()` only ever enqueued on the private engine. The shared engine exclusively fetched. **A joiner could receive and never send.**
- Worst: `SharingView.refresh()` ran `reconcileGrants` on every device, and `ensureShare` writes to the private database. On a joined device it would find no household share and _create one_ — an empty second household with that device as its owner, syncing to nobody. The roster would have read "This family's owner."

None of the three fails loudly. The outbox drains, the screen looks right, and no record reaches the family.

## The rule

`HouseholdSide` is `.owner` or `.joined(ownerName:)`, and it carries the owner name, the database scope, and `zoneID(for:)`. `FamilyZone` now has `id(ownedBy:)` with **no zero-argument version** — the default is exactly how this went unnoticed, because it compiled everywhere and was wrong on half the devices.

**Only the shared database is evidence.** Private zones prove nothing: `start` creates them eagerly on first launch, so every device has them whether or not it ever owned a household. A zone this app recognises appearing in the _shared_ database can only have arrived by an explicit acceptance.

**Two different owners is refused rather than picked between.** A device that has joined two households has no correct answer, and the two ways of being wrong are not equal: staying on the owner side makes an invitation look like it did not take, which is visible and recoverable; guessing writes one family's child data into another family's store, which is not. `SideResolution.ambiguousOwners` carries the reason so the admin screen can say it.

One `HouseholdSideProvider` is shared by the sharing layer and the sync engine. Two caches can disagree, and the state where they do — accepting invalidates one and leaves the other answering `.owner` — is precisely the state where writes go to the wrong database.

## What follows from it

- Owner-side operations (`invitation`, `removeParticipant`) throw `SharingFailure.notTheOwner` on a joined device. `reconcileGrants` returns 0 instead, because the admin screen runs it on every refresh and a joined device opening it is ordinary.
- `participants()` reads the household share from the shared database when joined, and **never creates**: "missing" there means _not shared with me_.
- `start(kids:)` is now async and resolves the side first. A device that cannot reach CloudKit to find out does not sync at all, which is the harmless way to be wrong.
- The admin screen draws a joined device a sentence naming who is in charge rather than hiding the section — the absence of a button is indistinguishable from a bug.

## Still unverified

Everything here is reasoned from the API and tested against stubs; **no participant has ever accepted any of this**. The resolution rule, the two-owner refusal and the per-side zone IDs are covered by tests that need no account. What a real acceptance does — including whether `shareParticipants(forUserRecordIDs:)` resolves an account known only from a share — is unchanged and still open.

### The invite flow is wired end to end, and two decisions changed to allow it
Built, and the reason it is one entry rather than four: the four gaps were not independent. A tapped link that is dropped, a joiner nobody can name, a second grant step that only ran from one screen, and a device roster that did not exist were each blocking the same thing — a second adult actually arriving.

## The tapped link was reaching the app and being discarded

`CKSharingSupported` is in `Info.plist` and has been. **That gets the app launched and nothing more.** No `application(_:userDidAcceptCloudKitShareWith:)` existed anywhere, and `FamilySharing.accept(metadata:)` — which has been on the protocol the whole time — had no caller in `Apps/`. So the system handed the share to a delegate that did not implement the method, and the tap did nothing: no error, no screen, no record. Meanwhile the sharing screen told the parent "if the invitation was sent to this device you can just tap the link", so the one wholly broken path was the one the copy recommended.

Now: a `ShareAcceptanceDelegate` via `UIApplicationDelegateAdaptor`, and a `ShareAcceptance` inbox between it and `Session`. The inbox is not indirection for its own sake — on a cold launch the delegate runs _before_ there is a session, so the metadata has to outlive the callback. It is a queue rather than a slot because a dropped second link would be silent.

**Acceptance does not ask.** By the time the metadata arrives the system has shown its own confirmation and the person has tapped through it. It also _cannot_ ask: a link tapped on a shared iPad lands while the kid's player is on screen, and nothing about the household's grown-ups belongs there. The outcome is recorded and reported on the sharing screen instead.

## A `CKShare.Participant` cannot be named, so the name comes the long way round

`GrownUp.accountRecordName` was specified as captured _at acceptance_ and nothing captured it — `claim(account:)` had exactly one caller, `SyncApply`, which is the path that reads the field from _another_ device. So a co-parent who joined was a participant record and never became a row, and the roster could only render "Grown-up".

The field cannot be filled from the share: a participant carries `nameComponents` and a `lookupInfo` holding an email address, and both stay untouched by decision — 5.1.4's trigger is a persistent identifier beside a minor's data, and an email address next to a child's search history is that combination.

So the claim is made by the person: `ActingGrownUp`** — already a statement of "I am Dad", already behind the gate — is promoted to a household fact when the account signed in on that device is known.** That pairing is the upgrade `accountRecordName`'s own doc describes; either half alone is not checkable.

`Family.claimAccount(_:for:)` holds the one invariant worth having: **one holder per account.** The roster's lookup is `first { $0.accountRecordName == id }`, so two holders makes the answer depend on roster order — it would read as a settled fact and be a coin toss. The way that happens is ordinary, not exotic: a shared iPad where both parents tap their own name. A claim therefore _moves_, un-claiming whoever held it. Safe only because the field is a hint that opens no gate and widens no reach; the cost of moving it wrongly is a name to correct, and the cost of not having it is a roster that can never name anybody.

It writes nothing when the answer is unchanged, because it runs on every launch and a stamp per launch would put the whole roster in the outbox once per launch per device.

## Sync runs by itself, and the precondition was met rather than waived

The engine was deliberately manual, and the recorded reason was specific: a co-parent could arrive holding the household zone and none of the kid zones, which looks exactly like sync being slow. That happened because `reconcileGrants` — the second step every invitation needs, since a link carries one share and a household is one zone plus two per child — ran only from `SharingView.refresh()`.

It now runs in `Session.syncPass()`, on launch and on every foreground. **That was the condition, so the decision is discharged, not overridden.** Pushes also fire fire-and-forget from `saveLists` and `commitDeviceChanges`: a parent's deny should not wait on iCloud, and a revocation's whole point is reaching a device that will not be asking.

**Launch order is load-bearing.** Acceptance runs _before_ `resolveBinding`, because `resolveBinding` writes — it stamps this device's row — and therefore spawns a push, and a push before the acceptance addresses the private zones nobody else can see. Acceptance needs nothing the binding provides, which is what makes the ordering free.

`Session.isJoining`** closes what ordering cannot.** A link can be tapped mid-session with a detached push already in flight; accepting changes which database this device writes to, and `SyncEngineHost` resolves the side once at `start`. Outbound paths stand down for the length of an acceptance and re-check after the await, because building the engine talks to CloudKit and an acceptance can begin and finish inside that suspension. Then `restartSyncEngine()` — an engine built before acceptance keeps answering `.owner` forever.

## Reading a roster is not consent to publish one

Found while making reconciliation automatic, and it would have been a live defect the moment it was: `ensureShare`** created.** `participants()` called it, so merely opening the sharing screen minted a zone-wide `CKShare` on a household that had never invited anybody — and moving reconciliation to launch would have minted one on every zone of every household on every launch, turning "this family is shared" into a consequence of opening the app.

`existingShare(for:)` is now the read path for `participants`, `reconcileGrants` and `removeParticipant`, and `invitation(for:)`** is the only creator.** The absence of an anchor share is a real answer: nothing has been offered, so nothing is outstanding. Reconciliation for an outstanding grant still creates, because by then an invitation exists and creating the rest is what the second step _is_.

## The device roster, which two strings already promised

`DeviceRecord.revoke()` and `restore()` had no caller anywhere in the app, and enrolment was a one-time screen with no way back. Two pieces of shipped copy assumed otherwise: `EnrollmentRefusal.revoked` says "a grown-up can let it back in from the device list", and `DeviceSetupView` says which child a device opens into can be changed "behind the passcode". `DeviceRosterView` makes both true, and adds the role, which had no path at all once a device was enrolled.

Three rules it enforces that are not obvious from the screen:

- **Revoking the device in your hand is refused.** Revocation is a tombstone that `BindingResolver` puts above every other clause, so the device reads it about itself and shows a dead end — whose only exit is this screen, behind the gate, behind the player just withheld. On a one-device family that is unrecoverable. The locked-device copy already said "on another device"; this is the half that makes the sentence true.
- **Revoked rows stay on screen.** The row _is_ what the revoked device reads; a parent who cannot see it cannot undo a mistake.
- **Rebinding a remote device is allowed and the passcode rule is not skipped.** It cannot be checked from here — a Keychain on other hardware is not a fact this device holds — so it is enforced where the answer exists: the target device re-runs it through `BindingResolver` on its next launch and locks itself on `.noGate`. The screen says so rather than implying the change is complete. Role changes stop at _this_ device: `parentOnly` means "no player on this hardware", and deciding that about a device you are not holding is how an iPad ends up with no player and nobody near it to notice.

## Still unverified, and the list is unchanged

Everything above compiles, the packages pass, and the iOS build is clean. **No participant has accepted any of it.** Probe A's participant-write half is untouched and is still this design's kill condition; Probe B is untouched. Specifically unproven: whether `application(_:userDidAcceptCloudKitShareWith:)` is delivered to a SwiftUI app's `UIApplicationDelegateAdaptor` rather than swallowed by SwiftUI's own scene delegate (reasoned from the documented fallback and from Apple's samples, which is not evidence); whether `shareParticipants(forUserRecordIDs:)` resolves an account known only from a share; and whether the account record name a joiner claims survives a reinstall, which binding rule 10 already assumes it may not.

### Measured: the owner side of the invite holds, and one claim above is now too pessimistic
Probed against the real container from a simulator with an account signed in. Method and the full result table are in **Open Questions and Research Tasks**, under _Measured: the owner-side sharing read path_; this is what changes for the design.

**The section above says the read path is "reasoned from the API and tested against stubs". That is no longer the whole story for the owner half.** Three of its claims are now measured:

- `existingShare(for:)` **finds a share that exists.** Observable as a second `invitation(for: .child)` returning a URL identical to the first — a miss would have minted a second share with a new token. Every read in `CloudKitSharing` depends on this and none of them could be tested off-device.
- **It returns nothing for a zone with no share**, so `reconcileGrants` running on every launch does not publish a household nobody invited into. That was the precondition for automatic sync, and it is now checked rather than argued.
- `SharePlan`**'s matrix lands where it says.** A child invitation put zone-wide shares on exactly that child's two zones and left `household` unshared — the row that, wrong, is a child holding the roster, the devices and the passcode epoch.

**Nothing about the kill condition changed.** Probe A's participant-write half is untouched and still gates everything downstream of Stage 5; a simulator has one Apple Account, so this could only ever have been the owner side. The delegate-delivery question is _also_ still open for the same reason — it needs a real share URL, which needs a second account — so the tapped link remains the one path in this flow that has never been exercised end to end.

**One thing the probe design is worth copying.** It ran entirely in zones named after a kid UUID that does not exist, using the `.child` role because its anchor is `kid-<uuid>-work` rather than `household`. A diagnostic that shares the real household zone has changed the thing it was measuring, and "the roster now lists somebody" is not a state to discover later without knowing why.

### Consent is a row now, and coverage is per child
Stage 8's first item, built. The rest of Stage 8 is untouched and two parts of it are not engineering.

**Why this stopped being deferrable.** It was listed behind the sync work, and the sync work landed — `Session.syncPass()` runs on launch and on every foreground, so a child's records now reach Apple's servers without anybody pressing anything. `ConsentRecord` had been fully wired for sync since the schema was paid for (outbox, mapper, `SyncApply`) and had **no local writer**, so the answer to "what consent did you record" was an empty table.

## The rule, and it is per child

`FamilyStore.Consent` is a pure function beside the record, for the reason `BindingResolver` is one: the interesting case is not the first invitation but the second.

**An agreement given when a family had one child does not cover the child added next month.** A screen that remembered "they already agreed" would hand out a second child's search history on the strength of an agreement about their sibling — so coverage is a set of kid identifiers, stored as what was exposed _at that moment_ rather than derived later, and the next invitation asks again. Thirteen tests, the load-bearing one being exactly that.

Two further asymmetries, both deliberate:

- `shareHousehold` exposes **every** child, because there is no per-adult scoping anywhere in this design — a participant holds the household zone and both zones of every kid. `childAccountParticipates` exposes exactly one.
- **Consent for one scope is never consent for the other.** The child-account ask is the larger one: it makes a minor's own Apple Account a share participant. Letting either stand in for the other is the one shortcut that would make the row meaningless.

A household with no children needs no agreement, which falls out of the set arithmetic rather than being a case.

## The screen, and what it can honestly claim

`ConsentSheet` sits before the first invitation of each kind, behind the gate and **not the gate reused as consent** — 5.1.4 is explicit that a parental gate is generally not the same as securing consent. It names the children by name, because "your children" would hide the difference the rule exists to surface. Dismissing declines; the only path that records an agreement is the button that says what it agrees to. The row is written **before** the link is minted, and a save failure stops the flow — an invitation whose consent failed to write is a live share with nothing recorded.

**What the row can and cannot say.** The adult is identified two ways where both exist: the acting grown-up they selected behind the gate, and the opaque record name of the Apple Account signed in here. Either may be absent, which the record allows, and the screen says so out loud when nobody is selected. That is the honest maximum — **nothing in this app verifies that the person behind the passcode is a parent**, and a row implying otherwise would be worse than one admitting it.

## The claim in CLAUDE.md is reworded, because it had become false

_"Nothing leaves the device"_ was true while sync had to be asked for by hand and is not now. Replaced with the wording this page specifies: no server of ours, no third-party analytics SDK, no PII to third parties, and the family's records stay in the family's own iCloud where we cannot read them. The note there says not to restore the old sentence and not to write "CloudKit sync does not change our COPPA posture" as a fact.

A second occurrence of the phrase in `STYLE.md` was about a UI change's blast radius rather than the privacy position, and now reads "no network call" — the old phrasing meant a grep for the retired claim still found something that looked like an assertion of it.

## What is left of Stage 8, and none of it is code

- **The wording needs counsel.** It is written to be plain and factual and it is not a legal opinion. The residual risk this page already names is unchanged: 5.1.4's trigger is the _capability_ to share a minor's personal information, which the share creates whoever holds the bytes.
- **A privacy policy still has to ship**, and it is not an agent's to draft.
- **ADP 3.3.6(D)** is still unanswered and still blocks the business model.
- **The production CloudKit schema promotion** remains the one-way door at the end, gated on the checklist — unchanged by any of this.

### Clearing history reaches the other devices now
`HistoryClearRecord` was in the same state `ConsentRecord` was in earlier: fully wired for sync — outbox, mapper, `SyncApply`, in `syncedModels` — and **constructed only when it arrived from somewhere else.** Nothing wrote one locally, and `Kid.deleteHistory` used the plain `delete(_:)` rather than `tombstone(_:)`.

**So "Clear logs" was local-only.** The four event tables and `RecentTrailRecord` are in `neverSyncs`, so no tombstone would have helped either — those rows never travelled and each device's copies were only ever its own. A parent clearing history on their phone cleared their phone's report and left the child's iPad holding its own history and its own home screen, listing what they had been doing. Which is the failure `HistoryClearRecord`'s own doc comment describes, written before there was anything to write it against.

**Worth being accurate about the cause:** this predates automatic sync and was not caused by it. What changed is that the invite flow works, so a second device stopped being hypothetical.

## The instruction is what travels

A clear is now a statement about a **range** rather than about rows: everything at or before `clearedThrough` goes, whenever it turns up. Three properties fall out of that, and all three are properties of taking a maximum, which is why the maximum is what `HistoryClears` tests exhaustively — it is idempotent, independent of arrival order, and effective against rows that had not been written yet when it was issued.

The pieces:

- `Kid.deleteHistory(at:issuedBy:)` writes the record itself. Inside the method rather than at the call site, because a clear that does not record itself is the bug and there is no caller for which that is right. `deleteEverything` inherits it.
- `clearedThrough` is **the moment of the clear, never **`distantFuture`**.** A clear is a statement about the past; one reaching forward would keep deleting a child's listening until somebody noticed.
- `HistoryClears.boundary` takes the **furthest** instruction, not the newest-issued. Two parents clearing at once produce two rows, and picking by `issuedAt` would let a clock skew of a second undo a deliberate deletion.
- A **device-local watermark** records what this device has acted on — `UserDefaults`, beside `DeviceLibraryState` and `ActingGrownUp`, because it is a different fact on every device. Losing it fails safely: everything looks unapplied, and applying twice deletes nothing the first pass left behind.
- `HistoryClearApplier` is separate from `deleteHistory` because that one is _unbounded_. Conflating them would have a clear issued last Tuesday, arriving today, delete a week of listening nobody asked about.
- The watermark advances **only after the deletions are saved**, so a crash between them leaves the clear looking unapplied.

## Two decisions inside the applier worth recording

**A summary containing any cleared events goes**, judged on the start of its period rather than its end. One outliving the events it was derived from is a record the parent asked us to destroy, and a summary straddling the boundary is partly made of them — so this errs toward destruction, which is what the instruction asked for.

**The Recent shelf goes wholesale rather than by date.** It is a projection over the visits being deleted, and `RecentsProjector` recomputes it unconditionally; deleting trail entries by their own timestamps would leave a trail disagreeing with the visits it is supposed to be derived from. On screen the session blanks the shelf and _then_ reloads it, so the wrong answer for a frame is "less than there is" rather than something a parent was told had been deleted — which matters because a bounded clear does not necessarily empty it.

## The cost, stated

**Latency.** Application happens on launch and on each sync pass, not the instant a record lands. Absorbing happens inside `SyncEngineHost`, which knows nothing about kids or projections, and threading a multi-table delete onto the path that receives every record is the wrong shape. So a clear issued on a parent's phone reaches a child's iPad on its next foreground. That is the right trade for this one and not for a deny: a deny decides what may play, a clear does not decide anything, it destroys.

**Not done, and belonging to Stage 7:** refusing _export_ of rows beneath the watermark. There is nothing to refuse yet — events do not sync as rows and segment export does not exist — but when `ActivitySegmentRecord` gains a writer, the watermark has to gate it, or a device that had not yet applied a clear will export the rows it was told to destroy.

Eighteen tests, including both arrival orders converging, the bounded late arrival, sibling isolation, and the shelf.

### Stage 7: segment export, and the interlock with clearing
Events travel now. Two halves were missing, not one: **nothing packed a segment and nothing unpacked one.** `ActivitySegmentRecord` was constructed only in `SyncApply`, so an arriving segment was stored and never read — a co-parent accumulated opaque blobs and their report was empty.

## Why the payload format needed almost no new code

`PlaybackOrigin` was already `Codable` through its frozen `StoredOrigin`. `BlockReason` had the identical `StoredReason` shape and no conformance, so it got one the same way — and for the same stated reason: an origin or a reason is now written in two places, and a synthesised shape for the second would drift from the columns the first uses.

The four event values are `Codable` **with explicit frozen **`CodingKeys`, declared in `Events.swift` beside the properties they freeze because Swift only synthesises in the type's own file. Short keys, since these are the highest-volume bytes in the system. A test asserts the wire keys rather than the round trip alone — a property rename that silently changed the format would otherwise pass everything.

No parallel DTOs. A DTO per event is a second definition of the same fields, and the two drift.

## What makes it safe

- **Idempotent by row identity, not by bookkeeping.** Each payload row carries the identifier of the record it came from, so absorbing inserts only ids it does not have. No `absorbedAt` column, no device-local set of segment ids growing without bound — and a re-export under a churned `deviceID` becomes harmless rather than a duplicate.
- `exportedAt` **is stamped only after the segment holding the row is saved.** The other order loses a child's history with everything reporting success.
- **Resumes rather than restarts.** `index` continues from the highest already written for that `(kid, device, day, table)`, so an existing segment is never overwritten by one holding different rows under the same key.
- **UTC day, not the device's calendar.** The day is part of the record key, so two devices in two time zones must agree which day a row belongs to.
- **A version we do not know is kept and skipped, never dropped.** The writing device still has the rows and a later build here will read it; deleting would lose a child's history to a version check.
- `originatingDeviceID`** comes from the segment**, not from the importing device. It is the cheapest forensic column available and worthless if absorbing rewrites it.
- A row whose own columns do not read back is skipped **and not stamped exported**, so it waits for a build that can read it.

## The interlock, which is the part worth remembering

The previous section predicted this and it came due immediately: **a clear reaches rows that had not arrived when it was issued, and a segment written by a device that had not heard about the clear is exactly that case.** Absorbing without checking resurrects the history a parent was told had been deleted — and it comes back on the _other_ parent's phone, where nobody is looking.

So `unpack` computes each kid's clear boundary from the `HistoryClearRecord`s it holds and skips rows at or before it, with the same inclusive comparison the applier uses on the rows it deletes. A row that cannot say when it happened is **not** treated as cleared: the safe direction there is keeping a row the parent may not have meant to keep, rather than discarding a child's history because a payload field did not read back.

**And the order in **`Session.syncPass()`** is load-bearing.** Clears, then pack, then push, then absorb. Pack before clearing and this device exports the rows it was just told to destroy — which is the failure the previous section named as the thing to watch for when export arrived.

## What is left of Stage 7

**The retention sweep**, and it is still gated on a decision rather than on engineering. The maintainer has settled half of research question 6: **a weekly summary keeps raw search terms.** The consequence to carry forward is that the summary inherits the sensitivity of the events it replaces, so aging events out is a storage improvement and no longer a privacy one — the COPPA argument for a short window is weaker than it looked when the question was written.

The window itself is undecided and **nothing sweeps.** Also still absent: a local writer for `WeeklySummaryRecord`, which is the summariser. Segments now make that worth building, because a summary computed before export existed would have covered only the events of the device computing it and been silently partial for any kid with two devices.

### The passcode epoch is wired, and rotation is the revocation path
Stage 6's last clause. `PasscodeEpochRecord` was the third record in the same shape as `ConsentRecord` and `HistoryClearRecord`: built only in `SyncApply`, with `PasscodeStore.clear()` having no caller anywhere and `AdminGate` not knowing epochs existed. Two devices held unrelated local codes, changing one left the other opening to the old code forever, and there was no way to take a seen code back.

## The KDF, and why the work factor is not the point

PBKDF2-HMAC-SHA256. CryptoKit at this floor has HKDF and no PBKDF2, and HKDF is the wrong tool — it expands strong material, it does not stretch a weak secret. The local `PasscodeRecord` keeps its single-round SHA-256, with its own stated justification: that hash never leaves the Keychain and this one goes to iCloud.

**No derivation protects a four-digit PIN, and that is fine here.** Reaching this verifier means extracting a private CloudKit zone from a family's iCloud and brute-forcing offline — and a child who can do that **has already beaten Screen Time**, which is the containment this design openly says it cannot enforce. The gate stands between a child and a settings screen; it was never a barrier against someone holding the family's iCloud data, and building it as one spends effort where the threat model has already collapsed. Maintainer's call, recorded as such. The iteration count makes the cheap attack not free; `CKRecord.encryptedValues` keeps Apple out; the household zone is held only by co-parents who already have admin. The one residual worth naming is a parent reusing the PIN somewhere that matters more, which is the concern the local record already names.

If it ever needs to resist someone holding the verifier, the answer is more digits, not more iterations.

## Four states where there used to be a boolean

`AdminGateView` asked `!isPasscodeSet`, which conflated three things. `PasscodeEpoch.challenge` is pure and beside the gate, for the reason `BindingResolver` is, and two of its clauses exist because collapsing them was a hole:

- **Unreadable is never absent.** A Keychain that errored used to read like a device nobody had set a code on — and the screen that asks is the one offering to _choose_ one. The gate now draws a dead end that offers nothing in that state.
- **Choose only when there is no gate anywhere.** A device with no local item, in a household that has an epoch, must _enter_. Otherwise joining a family and then setting your own admin code is a bypass, and the child's own iPad is what would do it.
- A local epoch **below** the household's is stale: the code was rotated elsewhere and only the new one works.
- **Equal epochs check locally**, which is what keeps the gate working with no network — the ordinary case, and the one that must never depend on iCloud.

A device _ahead_ of the household still checks locally: its own item is current by construction and the record simply has not caught up.

## What changed around it

- `isPasscodeSet`** now means rule 8's sentence** — "this family has a gate or this device has one" — and both `BindingResolver` and `Enrollment` read it. A device with no local item in a household that has an epoch _is_ gated: it will demand a code the child does not know. Reading only the local item let that device open a kid's player with `Enrollment` believing nothing gated it. It fails closed the other way too: a kid's device whose epoch record has not arrived is refused, which costs one parent typing a code.
- **Adopting on success.** A device that verified against the household verifier writes a local item at that epoch, returning to the offline fast path.
- **Backfilling for families that predate this.** A passcode set by an older build left no epoch record, so a second device joining that family would reach `.choose`. It is written on the first successful local unlock instead — the one moment the app holds the passcode itself, and one where the parent has just proved they know it. Nobody is asked anything.
- **Rotation requires the current code** even though the parent is already through the gate. The gate stays open after one entry, and "already inside" is not "knows the code" on a device somebody left unlocked.
- A rotation to the **same** code is refused rather than written: every other device would demand a "new" code identical to the old one, which reads as the family's gate having broken.

## One bug worth recording

The local Keychain item grows an epoch, appended, with absence as the migration — a pre-epoch blob reads back at 0, which sorts below the first epoch and therefore reads as stale rather than current. The first version of that decoder asked whether _more than four bytes_ followed the salt, which is true of a 48-byte pre-epoch item: it read the tail of the hash as an epoch, and **every existing install would have stopped recognising its own passcode.** Both widths are fixed, so exact length is the discriminator, and there is a test named after it.

## Still not done

`PasscodeStore.clear()` still has no caller, and that is now correct rather than a gap: rotation supersedes a code by writing a new epoch, which is what revocation means here — there is no state in which deleting the local item is the right move. And none of this has run between two real accounts; a second device demanding a rotated code is reasoned and unit-tested, never observed.

## Review
_Not reviewed._

## Open notes
_None._
