# Build and Release Setup

**Status:** restating

## Sections
### Motivation
We want to save time and effort, so this document outlines some best practices.

1. MusicKit does not work until the capability is enabled on the App ID.

1. The Family Controls entitlement needs a manual approval from Apple, per bundle identifier, reported at four business days to several weeks.

There is also a floor that was wrong for weeks. The packages declared iOS 15 while using `MusicLibraryRequest` (iOS 16) and committing to SwiftData (iOS 17). Nothing caught it because `swift build` targets macOS.

### Overview
- Project and account setup, plus the platform floor.

- The entitlement request and the App ID capability go in before the work that needs them.

- iOS 17 and macOS 14 are the lowest versions consistent with decisions already made.

### Data model & types
Mostly build-time facts. Writing them as values keeps them checkable.

```swift
/// Each entry is a consequence of a decision made elsewhere, not a preference.
enum PlatformFloor {
    static let iOS   = "17.0"   // forced by SwiftData
    static let macOS = "14.0"   // forced by ApplicationMusicPlayer

    /// Kept so nobody simplifies the number downward.
    static let musicKitCore      = (iOS: "15.0", macOS: "12.0")
    static let applicationPlayer = (iOS: "15.0", macOS: "14.0")
    static let libraryRequests   = (iOS: "16.0", macOS: "14.0")
    static let swiftData         = (iOS: "17.0", macOS: "14.0")
    static let familyControls    = (iOS: "15.0", macOS: nil)   // Catalyst only
    static let findEquivalents   = (iOS: "26.4", macOS: "26.4")
}

struct ProvisioningItem {
    let name: String
    let identifier: String?     // entitlement key, where there is one
    let grantedBy: Grantor
    let leadTime: LeadTime
    let blocks: [String]        // what cannot proceed without it
}

enum Grantor { case selfServe, appleReview }
enum LeadTime { case immediate, days(min: Int, max: Int) }

struct ListingDecisions {
    let ageRating: String
    let kidsCategory: Bool      // sticky: binding on all future updates
    let privacyLabels: [String]
}
```

### Algorithm
**Ordering by lead time, not dependency.**

```text
1. start the clocks first — both are cheap and neither needs code:
   1.1 enable MusicKit on the App ID
       (Identifiers -> App Services -> MusicKit)
       native apps then get automatic token handling: no server, no key
   1.2 submit the Family Controls distribution request, per bundle id and per
       Screen Time extension
2. only now is anything Apple-facing testable
3. targets, entitlements, Info.plist
4. do not let 1.2 block a release
```

**Deriving the floor.** Run whenever a dependency is added.

```text
1. collect the minimum OS of every API actually used
2. floor := max of those, per platform
3. compare against the declared platforms in every Package.swift
   a declared floor below the derived one is a latent build failure,
   invisible while building for macOS
4. a merely desirable newer API does not raise the floor; guard it with
   #available
```

### Invariants & limits
- The declared floor is never below the highest floor of any API in use.
- The floor is derived from dependencies, and each entry records what forces it.
- A newer API is adopted behind `#available`, not by raising the floor, unless the feature is load-bearing.
- Native MusicKit apps use automatic token handling. No developer token, no key, no server of ours.
- No release depends on a date for an Apple approval.
- Every bundle identifier carrying Family Controls has its own approved request.
- Background audio mode is declared in Info.plist.
- Privacy nutrition labels declare the child search and listening history, even though it never leaves the device.
- Screenshots show real playback context, since the MusicKit terms restrict Apple Music artwork outside playback and playlist contexts.
- The Kids Category decision is treated as permanent.
- Claims about child-account behaviour are only made after running on a real under-13 account.

### Failure & concurrency semantics
**The floor being wrong is silent.** This already happened: iOS 15 declared while using iOS 16 and 17 APIs. Nothing failed, because `swift build` targets macOS and the macOS floor hid it. It would surface the first time someone targets a phone. SwiftPM cannot cross-compile to iOS without a Swift SDK, so the check is reading availability annotations — a discipline, not a safety net.

**Entitlement refused or delayed.** Development builds keep working; shipping builds cannot carry the capability. Treating approval as a dependency of a release date turns an unknown queue into a slipped launch.

**MusicKit capability not enabled.** Everything Apple-facing fails in ways that look like code bugs. Verify it before the first device run.

**The Kids Category is one-way in practice.** Deselecting it later does not release the obligations, because customers already expect them.

**Simulator false confidence.** MusicKit behaviour there is unreliable and Screen Time cannot be tested at all. A green simulator run is not evidence.

**Concurrency.** None. The only ordering hazard is human: doing the long-lead items last.

### Data dependencies
**The MusicKit capability** — self-serve, immediate. Blocks everything Apple-facing. Before it is on, failures look like code bugs.

**The Family Controls entitlement** — Apple, manual, per bundle identifier, four business days to several weeks. Blocks shipping shielding; blocks nothing in development.

**A real family test setup** — an under-13 child account in a Family Sharing group with an Apple Music Family plan, plus hardware. **We already have this**, which removes what is usually the longest lead time and means there is no excuse for shipping on assumptions about that configuration.

**The Apple Developer Program License Agreement** — read at decision time. Section 3.3.6(D) constrains the business model, and the indirect-monetisation clause needs answering before anything is built on a paid model.

**The App Review Guidelines and Kids Category rules** — read before the age rating decision.

**The SDK's availability annotations** — the authoritative source for the floor. Nothing gates checking them except remembering to.

### Migration & existing data
**Nothing shipped, so nothing to migrate.** No users, no listing, no age rating on record.

What matters is the decisions that are effectively one-way.

**The Kids Category.** Selecting it commits permanently to no third-party analytics, no third-party advertising, and no PII to third parties. Deselecting later does not release it. The decision has to be made now, when we know least.

**Raising the floor is easy; lowering it is not.** Dropping to iOS 16 later would mean removing SwiftData, which is the storage layer.

**One floor change already happened** before any release, iOS 15 to 17. It cost nothing because nothing had shipped. The same change after launch would strand every user below the new floor.

**Bundle identifier changes are effectively impossible after launch.** It carries the MusicKit capability, the Family Controls approval, and the listing itself.

### Staged plan
**Stage 0 — start the clocks.** _Before any other stage._

- Ships: the MusicKit capability enabled, and the Family Controls request submitted.
- Does not: produce code.
- Exit test: a MusicKit call authenticates on device without a developer token, and the entitlement request has a confirmation.

**Stage 1 — the floor, verified.**

- Ships: iOS 17 / macOS 14 declared everywhere, with each contributing constraint written down.
- Does not: chase newer APIs.
- Exit test: every API in use is checked against the SDK's availability annotations, and none exceeds the declared floor.

**Stage 2 — the app target.**

- Ships: an Xcode project under `Apps/` with iOS and Mac destinations, background audio in Info.plist, local packages linked.
- Does not: set a final age rating or enter the Kids Category.
- Exit test: the app launches on a device and plays one song end to end.

**Stage 3 — the child account.**

- Ships: the whole flow exercised on the real under-13 account we already have.
- Does not: assume anything unobserved.
- Exit test: authorization, subscription check, search, playback and logging all run on that account, with every deviation written down.

**Stage 4 — listing decisions.**

- Ships: age rating, the Kids Category call, privacy labels naming the child history, a privacy policy.
- Does not: proceed before the 3.3.6(D) monetisation question is answered in writing.
- Exit test: the listing matches what the app does, particularly that the containment claim matches what the build enforces.

### Found while building it
Stages 0 through 2 are done. What they taught is that the failure mode this spec already names — _the floor being wrong is silent_ — is not one bug, it is a **class** of bug, and the whole class shares a defence.

**A build setting can be accepted and then ignored.** Two bit during Stage 2. Neither failed to compile, neither produced a warning, and both were caught only by reading values back out of the built app.

- `IPHONEOS_DEPLOYMENT_TARGET[sdk=iphone*] = 17.0` silently resolved to **26.5**, the SDK's own default. Shipped, that strands every device below iOS 26.5. This is precisely the failure this spec records for the packages declaring iOS 15, inverted — the same silence, the opposite direction. Set unconditionally, it takes.
- `INFOPLIST_KEY_UIBackgroundModes = audio` appears in `xcodebuild -showBuildSettings` and never reaches the generated plist. Background audio normally arrives via Xcode's capability editor writing a real file, so it needs one: a partial `Info.plist` holding that key, with `GENERATE_INFOPLIST_FILE` still on so the other keys merge. Background audio is an invariant of this spec, and it was absent from the built app while every setting said it was present.

**The defence is to verify the artifact, never the settings.** `plutil -p` on the built app's `Info.plist`. Not `plutil -extract KEY raw FILE` — without `-o -` that rewrites the file in place, so checking a key destroys the thing being checked. That one cost a confusing detour mid-verification.

**A partial **`Info.plist`** must live outside a synchronized file group.** Inside it, Xcode copies it as a resource as well as processing it, and the build fails with _multiple commands produce Info.plist_.

**A signed build says nothing about MusicKit.** MusicKit is an App Service on the App ID, not an entitlement, so it never appears in the provisioning profile. A clean signed build proves the bundle identifier matches and signing works, and proves nothing about the capability. The only proof is a catalog request that comes back — and a well-formed API error counts, while an authorization failure does not. Worth adding to Stage 0's exit test, which as written could be read as satisfied by a build that succeeds.

**Stage status.**

- **Stage 0** — MusicKit enabled and _confirmed_ by a real API response. The Family Controls request is still not submitted; it blocks nothing in development and every day of not submitting it is a day added to the queue later.
- **Stage 1** — iOS 17 / macOS 14 declared everywhere and verified in the built app, not just in the settings.
- **Stage 2** — project builds and signs for macOS, iOS simulator and device. The exit test is **not** met: nothing has played a song end to end yet.
- **Stage 3** — not started. Nothing has run on the real under-13 account.

## Review
_Not reviewed._

## Open notes
_None._
