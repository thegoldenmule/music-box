# Spec: Accounts, Devices and Sync

**Status:** restated

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

## Review
_Not reviewed._

## Open notes
_None._
