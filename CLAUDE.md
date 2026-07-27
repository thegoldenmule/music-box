# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A native iOS and Mac app that lets kids explore music inside walls the parent
sets. Playback is Apple Music through MusicKit, so the catalog is complete; we
control which parts of it a kid can reach.

Two halves of one app: a **parent admin** behind a passcode (kids, sandbox
level, allow/deny lists, preview, reports) and a **kid player** that is big,
simple, and has no escape hatches — no links out, no ads, no "more like this."

Three sandbox levels, set **per kid**, not per family:

| Level | Kid can reach |
| --- | --- |
| 1. `allowOnly` | Only what the parent added. No open search. |
| 2. `denyPlusAuto` | The whole catalog, minus explicit and minus parent denies. The default. |
| 3. `reportOnly` | Everything. |

Reporting runs in all three. Level 3 is the same app with the walls down — one
policy engine, one log, three configurations.

## Where the design lives

**Design docs are in the `Aural Sandbox` wiki workspace, not in this repo**
(`ws:ms3de17i-0024-ik1oty`, via the `wiki` MCP server in `.mcp.json`). Read the
relevant spec before changing behavior in a component; the specs carry the
reasoning, the invariants, and the staged plans.

- `The Idea` — product
- `What We Know About MusicKit` — verified API/licensing facts
- `Open Questions and Research Tasks` — what is still unmeasured, ranked
- `Major Pieces` — nine spec-restatements: Policy Engine, Catalog and Search
  Layer, Kid Player, Parent Admin, Activity Log and Reports, Accounts Devices
  and Sync, Keeping Kids In The App, Storage and Data Model, Build and Release
  Setup

Each package also has a substantial `README.md` covering its contract and the
decisions that go beyond the spec. Read those first — they are current.

## Layout

```
Packages/
  PolicyEngine/   what a kid may see or play — pure logic, no MusicKit, no UI
  CatalogKit/     the only layer that imports MusicKit
Apps/            app targets (Xcode projects) — nothing yet
Tools/           spikes and throwaway probes — nothing yet
```

`CatalogKit` depends on `PolicyEngine`; nothing depends on `CatalogKit` yet.
Packages are plain SwiftPM, Swift 6 language mode, and build from the command
line. Anything needing entitlements, signing, or an Info.plist goes under
`Apps/`.

## Build and test

```sh
for p in Packages/*/; do swift test --package-path "$p"; done
```

`swift build` targets **macOS**, so an iOS-only availability mistake compiles
clean here. That already happened once: the packages declared iOS 15 while using
iOS 16 and 17 APIs, and nothing caught it. When adding an API, check its
availability annotation against the declared floor by hand.

## Platform floor: iOS 17, macOS 14

Derived from dependencies, not preference. Each number is forced by something:

| Floor | Forced by |
| --- | --- |
| iOS 16 / macOS 14 | `MusicLibraryRequest`, `MusicLibrarySearchRequest` |
| iOS 17 / macOS 14 | SwiftData |
| macOS 14 | `ApplicationMusicPlayer` — no in-app playback below it |

Adopt newer APIs behind `if #available` rather than raising the floor.
`MusicCatalogResourceRequest.options = [.findEquivalents]` (iOS/macOS 26.4+) is
the current example. Lowering the floor later is not possible — iOS 16 would
mean removing SwiftData, which is the storage layer.

## Rules that hold across the codebase

**The policy engine is the single authority.** Every surface asks
`PolicyEngine.evaluate`. Nothing else decides what a kid may see or play. The
player asks *again* immediately before playback rather than trusting the UI only
offered allowed things — a UI that shows something the player then refuses is a
UI bug, not a safety failure.

**The engine is pure.** No I/O, no clock, no randomness, no throwing path. The
caller supplies ancestry. Keep it that way: it is the component most worth
testing exhaustively and it must be testable with no network, no subscription
and no device.

**`nil` rating is not `.clean`.** `ContentRating` is `.clean` or `.explicit` and
the property is optional; `nil` means "no rating available." This is a
three-state problem, never a boolean. `UnratedBehavior` decides, defaults to
`.block`, and that default is a guess until research question 3 is measured.

**Ancestry is resolved in batch, before anything is judged.** MusicKit returns no
relationships with search results, so a song arrives knowing nothing about its
album or artist. One `resolveAncestry` call per page, never per item. A verdict
computed on empty ancestry is *provisional*: deny fails open, allow-only fails
closed.

**Only CatalogKit imports MusicKit.** Everything above works in `CatalogItem`
and never sees a MusicKit type.

**Every stored identifier is an Apple Music catalog identifier.** Library picks
are resolved to catalog items (songs by ISRC, albums by UPC) before anything is
stored; library identifiers are never persisted. One namespace means a deny on
an artist reaches everything, and `PolicyEntry` needs no scope field.

**Search cannot be filtered at the API.** `MusicCatalogSearchRequest` has no
content parameter. All filtering is ours, client-side, after results return —
hence `FilteredCatalog`'s over-fetch loop, and hence the distinction between
`reachedEnd` (the source ran out) and `gaveUpEarly` (we stopped looking).

**Blocked items are kept, never dropped.** The activity report is built from them
with their reasons, including results the kid never saw.

**Logging is fire-and-forget and never on the playback path.** A dropped log line
is acceptable; a stalled player is not. No safety decision reads from the log.
Policy-entry writes are the opposite: awaited, with failures surfaced.

**Nothing leaves the device.** No server of ours, no third-party analytics SDK,
no PII to third parties. This is a legal position (COPPA and friends), not just
an architecture preference — the app records a child's search history.

**Four MusicKit affordances are deliberately never used**: personalized
recommendations, autoplay past the end of a queue, radio and stations, and the
user's own library as a browsing source. Each reaches unvetted material.

**Containment fails open.** Screen Time, Guided Access and Family Controls all
live outside our process and can be off without telling us. The app must work
correctly with none of them, and onboarding says so out loud: this app controls
what happens inside this app.

## Schema constraints to honor now

Nothing has shipped, so nothing needs migrating — but several first-release
choices are expensive to reverse:

- Records go in a **named custom CloudKit zone** from the first release. The
  default zone cannot be shared, and v1 is local-only but v2 shares the family
  zone across two parents' Apple Accounts.
- Stable UUIDs and `modifiedAt` on every record; nothing depends on insertion
  order or locally sequential ids.
- `mode` and `unratedBehavior` are **stored per kid**, never read from a global
  default at evaluation time — otherwise changing a recommended default silently
  changes what existing kids can reach.
- `displayName` and `artworkURL` are copied onto entries and events at write
  time so lists render offline and a delisted item still reads as a name.
  Artwork bytes are never copied into our storage.
- Event fields cost one column now and are absent forever if added later:
  `origin`, `originTerm`, `gaveUpEarly`, `secondsPlayed`, `deniedByID`.
- The admin passcode lives in the **Keychain**, not the app store, so it
  survives a reinstall.

## Known unknowns

Treat these as unmeasured, not settled. Do not write code that assumes an answer
without saying so.

1. How often `contentRating` is `nil` — decides the `UnratedBehavior` default and
   whether the over-fetch multiplier of 3 is generous or nowhere near enough.
   `Tools/RatingProbe` is meant to settle it; needs a device.
2. Whether ISRC and UPC are populated often enough on library items for seeding
   to be worth offering.
3. Whether `hasMore` behaves as inferred (it is inferred from a full page —
   MusicKit gives no total count).
4. Whether the license's indirect-monetisation clause (ADP License Agreement
   3.3.6(D)) permits a paid app. Unanswered; blocks business-model decisions.
5. Whether the app enters the Kids Category. The decision is effectively
   permanent once made.
6. The retention window for child event data — 90 days rolling into summaries
   versus keeping until deletion. Shortening it later destroys data a parent
   relied on.

The MusicKit capability is not yet enabled on the App ID, which blocks
everything Apple-facing. `MusicKitCatalogSource`, `MusicKitLibrarySource` and
`MusicKitAccess` compile against the real SDK and are otherwise unverified.

**The simulator is not evidence.** MusicKit behaves unreliably there and Screen
Time cannot be tested at all. Claims about child-account behavior hold only after
running on the real under-13 account.

## Style

Match the surrounding code. The existing packages favor small value types,
protocol seams for anything that touches the network, table-driven tests, and
comments that record *why* a decision was made where it is not obvious —
especially where a rule is deliberately asymmetric.
