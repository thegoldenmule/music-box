# Keeping Kids In The App

**Status:** restated

## Sections
### Motivation
The motivation is to do our best to help parents keep their kids in the sandbox.

### Overview
How far we go to keep a kid inside the app, and what we tell parents about the rest.

Four mechanisms, as a ladder:

1. **A passcode on the admin** — This stops the kid changing their own settings.
2. **Guided Access** — stops them leaving the app, but the parent turns it on by hand each session.
3. **Family Controls** — shields the Music app and Safari and stops the child deleting our app or signing out of iCloud. Needs Apple's approval, days to weeks, iOS only.
4. **The parent setting up Screen Time themselves** — free for us, mostly not done.

Ship the passcode, request the entitlement early because waiting is the cost, never let v1 block on approval, and say the limitation out loud in onboarding and on the store page.

### Data model & types
```swift
/// Observed, never assumed — all of it can change outside our app.
struct ContainmentState {
    let adminLocked: Bool                  // always true; our own gate
    let familyControls: FamilyControlsState
    let musicRestriction: MusicRestriction
}

enum FamilyControlsState {
    case unavailable        // macOS, or below the OS floor
    case notRequested       // entitlement held, guardian has not authorized
    case denied
    case authorized         // shielding possible; the app cannot be deleted
}

/// Screen Time's music content setting. There is NO API to read it, so values
/// are inferred from playback failures and `.unknown` is the normal state.
enum MusicRestriction {
    case unknown
    case inferredClean
    case inferredUnrestricted
}

/// What we promise, so onboarding and the store listing say the same thing.
struct ContainmentStep {
    let title: String
    let stops: String       // what it actually prevents
    let cost: String        // what the parent has to do
    let deepLink: URL?      // into the right Settings pane, where one exists
}
```

### Algorithm
**Onboarding.**

```text
1. state the limit before asking for anything:
   "This app controls what happens inside this app. If your kid can open the
    Music app, they can hear anything."
2. build the ladder for this platform:
     iOS   -> passcode, Screen Time, Guided Access, Family Controls if approved
     macOS -> passcode
3. show each step with what it stops and what it costs
4. deep-link into Settings where possible
5. never gate app usage on any of it
```

**Family Controls, once approved.**

```text
1. macOS -> unavailable; do not offer it
2. request authorization; a guardian approves, not the child
3. on authorized: shield the Music app and browsers
4. on denied: fall back down the ladder and say what is no longer covered
```

**A playback refusal from outside.**

```text
1. if the error matches an outside restriction and the item is explicit:
     record inferredClean
     log the block as restrictedOutsideApp, not one of our rules
     the kid sees the ordinary message
     the parent's report explains it and points at the setting
2. otherwise treat it as an ordinary playback failure
```

### Invariants & limits
- The app is fully usable with only the admin passcode. No containment step is a precondition for using it.
- The limitation is stated in onboarding before any permission is requested, and on the store listing.
- Onboarding and the store page make the same claim. Marketing never claims containment the app does not have.
- Family Controls is offered on iOS only.
- Family Controls authorization is a guardian's to give, never presented as the child's.
- A denied or unavailable step falls back to the next rung and says what is no longer covered.
- A refusal traced to an outside restriction is logged as `restrictedOutsideApp`, never attributed to a parent's own rule.
- The kid-facing message for an outside restriction is the same as any other block.
- Screen Time's music restriction is never relied on as a filter.
- `MusicRestriction` is inferred, so it is never presented to a parent as fact.
- Nothing here gates or delays playback.

### Failure & concurrency semantics
**Containment fails open, always.** Every mechanism lives outside our process and can be absent, denied or switched off without telling us. The app has to work correctly with none of them.

**Entitlement not approved.** Development builds work; TestFlight and App Store builds cannot ship the capability. Approval is neither guaranteed nor scheduled, so no release plan may depend on a date for it.

**Authorization denied by the guardian.** Shielding never activates. Fall back and say what is no longer covered rather than continuing to imply protection.

**Screen Time producing confusing failures.** Documented and unresolved on Apple's side: a hard `CONTENT_RESTRICTED` in MusicKit JS that Apple could not reproduce, and a Mac-specific "Failed to prepare to play" for explicit tracks. We cannot fix it, so we detect its shape and explain it.

**Inference being wrong.** A network failure at the wrong moment can look like a restriction. `MusicRestriction` is a hint for a support message, never a fact shown to a parent and never an input to a decision.

**The Mac.** No Guided Access, no Family Controls, and Command-Tab always works. A Mac build is a player with reporting, not a sandbox. That belongs in the store listing.

**Concurrency.** All state here is observed from the system, can change while backgrounded, and is re-read on foreground.

### Data dependencies
**Family Controls authorization** — needs the `com.apple.developer.family-controls` entitlement. Development works immediately; shipping needs a manual approval from Apple, per bundle identifier and per Screen Time extension, days to weeks. Until then this input does not exist in any installable build.

**Screen Time's music restriction** — **there is no API to read it.** This is the central limitation here. We cannot tell a parent what is in force, cannot pre-empt a failure, and cannot separate a restriction from a network error except by pattern. Everything about it is inferred after the fact.

**Apple Music's own parental controls** — set on the web, separate from Screen Time, also unreadable, and the two disagree often enough that developers have filed unresolved Feedback.

**Guided Access** — the parent turns it on manually. We cannot start it or detect it.

**Platform** — known at compile time, and it decides the whole ladder.

All of it can change while backgrounded, so none is cached across launches as though still true.

### Migration & existing data
**Nothing to migrate.** No installs, no authorizations, no shields.

The risk here is about what we have promised, not what we have stored.

Shipping at the passcode rung means onboarding says the sandbox covers the app only. Adding shielding later strengthens that, which is safe.

The dangerous direction is losing containment a build already claimed — an entitlement revoked, an OS change, an approach Apple stops permitting. No data migration fixes that; the parent has to be told in the app that something they relied on is gone.

So: never claim a rung the shipped build does not stand on, and treat any future loss of containment as a user-facing notification rather than a silent change.

One thing worth recording now: log which containment rung was in force during a session. Otherwise a parent reading an old report cannot tell whether a gap was their kid leaving the app or simply not listening.

### Staged plan
**Stage 0 — request the entitlement.** _Before anything else._

- Ships: nothing. It is a form.
- Does not: block any other stage.
- Exit test: a submitted Family Controls distribution request, describing a parental-control use case in terms that do not read as usage-data collection — Apple checks for that, and our reporting feature needs framing with care.

**Stage 1 — the passcode rung and the honest sentence.**

- Ships: the admin gate, plus onboarding and store copy stating the app controls only itself.
- Does not: shield or detect anything.
- Exit test: someone who has not seen the app reads onboarding and correctly answers "can my kid open the Music app?"

**Stage 2 — the ladder.**

- Ships: the platform-appropriate ladder with each step's cost, and deep links into Settings.
- Does not: pretend a parent completed a step we cannot verify.
- Exit test: a parent reaches the Screen Time music setting in one tap from onboarding.

**Stage 3 — explaining outside restrictions.**

- Ships: detection of the outside-restriction failure shape, logged and explained in the report.
- Does not: present the inference as fact.
- Exit test: with Screen Time set to Clean, an explicit track fails, the kid sees the ordinary message, and the parent's report names the real cause.

**Stage 4 — shielding, if approved.**

- Ships: guardian-authorized shielding of the Music app and browsers on iOS.
- Does not: ship on macOS.
- Exit test: with shielding active, the Music app is unreachable and the child cannot delete the app or sign out of iCloud.

## Review
_Not reviewed._

## Open notes
_None._
