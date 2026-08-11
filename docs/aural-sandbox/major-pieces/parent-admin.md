# Spec: Parent Admin

**Status:** restating

## Sections
### Motivation
We want to provide good controls to parents for letting kids safely explore music.

### Overview
The Parent Admin is where a parent sets things up and reads what happened. There are six main pieces: kids, mode, allow list, deny list, preview, and reports.

Preview renders the kid's home and a sample search through the kid's real policy and the real engine, so a parent can see what they have built before the kid does.

Blocks in a report carry a one-tap "allow this" that writes to the list. Over a couple of weeks the list assembles itself from what the kid actually looked for.

### Data model & types
```swift
struct Kid: Identifiable {
    let id: UUID
    var name: String
    var mode: SandboxMode           // stored explicitly, never defaulted at read time
    var unratedBehavior: UnratedBehavior
}

/// Absent means locked. There is no partially-unlocked state.
struct AdminSession {
    let openedAt: Date
    let idleTimeout: TimeInterval   // ~300s; re-gate after it lapses
}

enum GateChallenge {
    case passcode                   // set on first run, distinct from the device passcode
    case biometric                  // convenience only, never the sole route
    case adultTask(prompt: String)  // Kids Category form
}

struct PreviewResult {
    let home: [CatalogItem]
    let sampleSearch: FilteredResults?   // nil in level 1, where search is absent
}

/// A pending edit, so a seed of two hundred items is reviewed before it commits.
struct ListDraft {
    let additions: [CatalogItem]
    let discarded: [DiscardedItem]
    var kind: PolicyEntry.Kind
}
```

### Algorithm
**Opening the admin.**

```text
1. live session within idleTimeout -> open
2. otherwise present the gate; biometrics may satisfy it, passcode always can
3. on success, start a session; on failure, back off
4. on background or timeout, discard the session
```

**Adding from catalog search.**

```text
add(item, kind)

1. store PolicyEntry(kind, item.id)          // always a catalog id
2. store item.title and item.artworkURL alongside, so the row renders offline
3. invalidate the preview
```

**Seeding from the library.**

```text
seed(selection, kind)

1. imported := library.resolveToCatalog(selection)
2. show a draft: additions, plus discards with their reason
3. on confirm, add each addition
```

**Approving from a report.**

```text
1. add(blockedEntry.item, .allow)
2. offer widening to its artist or album, taken from the ancestry already on the
   logged item
```

**Preview.**

```text
1. build the engine from the kid's stored policy
2. home := level 1 ? the allow list : recents, filtered
3. sampleSearch := level 1 ? nil : a real filtered search
```

### Invariants & limits
- Every route into the admin passes the gate. No deep link or first-run path skips it.
- The admin passcode is set on first run and is distinct from the device passcode.
- Biometrics never replace the passcode route; a failed enrolment must not lock a parent out.
- The session is time-boxed and dropped when the app backgrounds.
- Preview uses the kid's real policy and the real engine over real catalog results.
- Every list entry stores a catalog identifier.
- A library seed is shown as a draft before it commits.
- Discards from a seed are shown with their reason.
- The deny list accepts artists, albums and songs.
- An entry stores the display name and artwork URL alongside the id.
- Switching the active kid happens only inside the admin.
- Catalog search in the admin is unfiltered; a parent picking what to deny has to be able to see it.
- The mode picker states what each level does and does not catch. Level 2 copy never implies explicit tagging covers themes rather than lyrics.

### Failure & concurrency semantics
**An entry whose item has vanished.** The row renders as unavailable, keeping the stored name, and stays on the list. A list that edits itself loses the parent's trust.

**A seed that resolves badly.** The draft shows what matched and what did not before anything commits. A seed is never partially committed unseen.

**Gate failure.** Repeated wrong passcodes back off with increasing delay. No hint about length, and no reset a kid could drive. Losing the passcode is a dead end, which argues for offering biometrics early.

**Preview disagreeing with the kid's device.** It is a snapshot, not a promise; the catalog can change between the two.

**Concurrency.** One device, one admin session, so nothing to reconcile. Once two devices sync, two parents editing one kid is a real conflict with no answer in this model, and last-write-wins over a whole list would discard someone's work. Settle it before sync ships.

**A verdict in flight.** Editing a list while the kid is playing does not interrupt the current track.

### Data dependencies
**Kids and their policies** — local, synchronous. The admin is the only writer.

**The admin passcode** — Keychain, not the app's own store, so it survives a reinstall.

**Catalog search** — over the network, unfiltered here, unlike the kid's side.

**The library** — needs authorization and `hasCloudLibraryEnabled`. The seed entry point is hidden when Sync Library is off, rather than shown and failing.

**Stored names and artwork URLs** — captured at add time so the list renders offline.

**The activity log** — local, read here for reports and approve-from-report. Once sync exists the report may lag the kid's session, and the screen should show when it was last updated.

### Migration & existing data
**Nothing to migrate.** No kids, no lists, no passcode.

Three things to get right in the first release.

**Passcode in the Keychain from day one.** Moving it later means a forced re-set or a migration that reads the location you wanted to stop using.

**Display name and artwork URL on every entry.** Added later, pre-existing entries render as bare identifiers until individually re-fetched — the offline case the fields exist for.

`mode`** and **`unratedBehavior`** stored per kid**, not as a global default with overrides. Otherwise changing a default later changes what existing kids can reach.

One migration is already visible: this version assumes one device and one admin, with no conflict resolution. Sync has to adopt that data without a parent losing a list.

### Staged plan
**Stage 1 — gate and modes.**

- Ships: first-run passcode in the Keychain, the gate, adding a kid, choosing a mode.
- Does not: lists, preview, reports, biometrics.
- Exit test: the admin cannot be reached without the passcode, and the passcode survives a relaunch.

**Stage 2 — lists by catalog search.**

- Ships: unfiltered search, add to allow or deny, grouped by type, remove entries.
- Does not: library seeding or bulk operations.
- Exit test: an artist on the deny list stops that artist reaching the kid's app on the same device.

**Stage 3 — preview.**

- Ships: the kid's home and a sample search through the kid's real policy.
- Does not: approximate anything.
- Exit test: preview and the kid's device agree for the same term, policy and minute.

**Stage 4 — making curation bearable.**

- Ships: library seeding with draft-and-confirm, bulk approval of an artist's catalogue, approve-from-report.
- Does not: add anything without the parent tapping.
- Exit test: a parent builds a usable level 1 list for a real child in under ten minutes, measured.

**Stage 5 — biometrics.**

- Ships: Face ID or Touch ID over the passcode, idle timeout, re-gate on background.
- Does not: remove the passcode route.
- Exit test: a failed biometric still admits the parent by passcode.

### Their Library: the admin edits the kid's shelf
A parent can now manage a kid's favorites and playlists directly, not only read them: add, remove, rename, reorder, delete. Four decisions shaped it, and the first three are the ones worth carrying.

**A separate screen from the report.** "Review Activity" reports on the shelf; "Their Library" changes it. One editable screen would have been fewer files, but a report a parent reads to understand what happened should not also be where a stray swipe deletes a child's work, and the wording each screen needs is different because the question is.

**A refused add offers the policy change, and the two offers are not interchangeable.** A parent's write goes through the same `PolicyEngine` the kid's does and throws the same `LibraryRefused` — there is no admin bypass, and the invariant _nothing in the kid's library is a permission_ stays exactly true. What differs is only what the caller does with the refusal: the dialog offers the change that would let it through, and retries once. Which change depends on the reason, and getting this wrong is the difference between the feature working and feeling broken:

| Reason | Fixable by allowing the item? | Offer |
| --- | --- | --- |
| `notOnAllowList` | Yes | _Allow “…” and add it_ |
| `explicitContent` | Yes — an allow on the item itself overrides the rating check | same |
| `unrated` | Yes, same rule | same |
| `deniedByParent(id)` | **No** — deny wins in every mode | _Remove that block and add it_ |

Offering a bare "Allow this" for a deny would be a button that visibly does nothing: the retry refuses again with the identical reason. The allow itself is a separate, explicit `PolicyEntry` write — the same call approve-from-a-block makes — and the favorite that follows is judged again by a rebuilt engine. A parent who cancels has granted nothing and placed nothing.

**The add sheet searches unfiltered.** Three reasons, and the first is structural: a policy-filtered search never returns a blocked item, so the refuse-and-offer path above would be unreachable dead code. At level 1 a filtered search returns _nothing_ unless the item is already allowed — empty exactly where a parent most wants to stock a shelf by hand. And it matches what the allow/deny list editor already does. Blocked results appear, badged with today's verdict; seeing a thing and being able to place it stay separate.

**Nothing a parent does reaches the kid's log.** The editor calls `MergedLibrary` directly and never routes through the `Session` methods the kid's controls use — two of those log a `reach: .reached` block when the engine refuses, which is right for a child who tapped something and a lie about a parent who did. A parent's refused add is a third category the codebase's "log transient blocks" rule does not cover: _a write that did not happen_. Surfaced in the UI, recorded nowhere.

**The bulk-seed seam went in ahead of the feature.** `MergedLibrary.addFavorites(_:origin:)` and `addSongs(_:to:origin:)` return a `LibraryPlacement` of what was placed and what was refused, resolving ancestry **once** per batch. Nothing calls them yet. They exist so that "pre-populate a kid's library from a subset of the parent's own Apple Music library" is later a screen rather than a rewrite of how writes are judged. This does not weaken the rule that library seeding must not run through `KidLibrary`: that rule governs the reading and the ISRC/UPC matching, which stay in `CatalogKit`'s `LibrarySource`. By the time anything reaches `KidLibrary` it is a `[CatalogItem]`, indistinguishable from a search result.

A seeded row's origin is `parent`, not `appleLibrary` — "the parent picked these out of their own library" is a different fact from "adopted from the account this device is signed into" — so the seed needs no further enum case. See the storage spec for the `kid > parent > appleLibrary` precedence and why the ordering is that way round.

Unverified: all three screens and their dialogs are untested — they live in `Apps/` and the simulator proves nothing here. The package layer beneath them is covered, which is where the judging lives.

## Review
_Not reviewed._

## Open notes
_None._
