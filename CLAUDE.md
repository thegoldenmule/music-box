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

**Never edit a `README.md`. They are generated from the wiki.** An edit here is
overwritten the next time they are generated, and worse, it puts the repo and
the wiki into disagreement while looking authoritative. To change what a README
says, change the wiki page it comes from and let generation carry it across.

Two files are the exception, both hand-maintained and safe to edit: this one,
and **`STYLE.md`** — how the app should look and move, and where Apple says so.
Read `STYLE.md` before any UI or styling change. It carries the availability
tiers against the iOS 17 / macOS 14 floor (getting a tier wrong is a build
failure, not a style disagreement), the motion vocabulary, the recipes for the
four set-pieces, and a list of approaches already assessed and rejected with
reasons — check that list before proposing one of them again.

The same goes for anything learned while working — a verified API fact, a
measured number, a decision. It belongs in the wiki (`What We Know About
MusicKit`, `Open Questions and Research Tasks`, or the relevant
spec-restatement), not appended to a README.

## Layout

```
Packages/
  PolicyEngine/   what a kid may see or play — pure logic, no MusicKit, no UI
  CatalogKit/     the only layer that imports MusicKit
  FamilyStore/    SwiftData persistence — kids, lists, activity log, the library
  AdminGate/      admin passcode and session backoff — Keychain, no UI
  KidLibrary/     the kid's favorites and playlists — the provider seam
Apps/
  AuralSandbox/  one Xcode project, iOS + Mac — currently a thin debug slice
Tools/           spikes and throwaway probes — nothing yet
```

`CatalogKit` and `FamilyStore` each depend on `PolicyEngine` and on nothing
else. `FamilyStore` deliberately does not depend on `CatalogKit`: catalog
metadata arrives as values a caller passes in, so storage builds and tests with
no MusicKit and no device.

`KidLibrary` is the one package that depends on all three. It exists because the
kid's library is the one feature whose data lives in two stores at once — ours
and the account's real Apple Music library — and `LibraryProvider` is the seam
that makes those the same shape. Callers hold `MergedLibrary` and never name a
provider. The Apple Music provider does not exist yet; the whole feature is
tested against stubs with no network and no device, which is why the seam went in
before it.
Packages are plain SwiftPM, Swift 6 language mode, and build from the command
line. Anything needing entitlements, signing, or an Info.plist goes under
`Apps/`.

## Build and test

```sh
for p in Packages/*/; do swift test --package-path "$p"; done

cd Apps/AuralSandbox
xcodebuild build -scheme AuralSandbox -sdk iphonesimulator   # checks the iOS floor
```

**The macOS app is not a concern right now, and its build is expected to fail.**
Do not chase it, and do not treat it as a regression introduced by whatever you
are working on. The failure is provisioning, not code: adding the iCloud
entitlements moved the Mac target off profile-free ad-hoc signing onto a real
development profile, and this Mac is not registered on it —
*"Provisioning profile … doesn't include the currently selected device
'Constantine'"*. Confirmed by overriding `CODE_SIGN_ENTITLEMENTS` back to the
sandbox-only file, which builds clean. Unsticking it means registering the
machine, either in Xcode or with `-allowProvisioningDeviceRegistration`
alongside `-allowProvisioningUpdates` — a decision for the maintainer, since it
consumes a device slot on the account.

**None of this means macOS support is being dropped.** The floor stays macOS 14,
the packages still build and test on macOS, and code must keep compiling for it
— `swift test` runs there and is still the main check. What is deprioritised is
the *app target* on macOS: its build failing is not news, and time spent on its
signing is time not spent on the thing being built.

So the app-level check that matters is the `iphonesimulator` build. `swift build`
targets **macOS**, so an iOS-only availability mistake compiles clean here. That
already happened once: the packages declared iOS 15 while using iOS 16 and 17
APIs, and nothing caught it. When adding an API, check its availability
annotation against the declared floor by hand. Building the app against
`iphonesimulator` is the closest thing to a real check.

Building to a **device** does not work on this machine yet —
`generic/platform=iOS` reports *iOS 26.5 is not installed*, and the iOS platform
component needs installing from Xcode → Settings → Components.

**Build settings can be accepted and then ignored.** Two have bitten already,
neither failing to compile: `IPHONEOS_DEPLOYMENT_TARGET[sdk=iphone*]` silently
resolves to the SDK default, and `INFOPLIST_KEY_UIBackgroundModes` never reaches
the generated plist. Verify anything load-bearing by reading it back out of the
built app with `plutil -p` — never `plutil -extract KEY raw FILE`, which
rewrites the file in place unless given `-o -`.

## Getting a build out

**Do not hand-assemble `xcodebuild` invocations for a release.** `Tools/ship`
owns that, and `Tools/SHIPPING.md` is its manual.

```sh
Tools/ship doctor      # fifteen checks, each with the steps that clear it
Tools/ship next        # the single next action — the loop to drive
Tools/ship release     # tests → bump → archive → verify → export → verify → upload
Tools/ship status      # has Apple finished, and can anyone actually install it
Tools/ship selftest    # its own unit tests
```

Every command takes `--json`: one object on stdout, all prose and subprocess
output on stderr. Exit codes are 0 ok, 1 failed, 2 usage, and **3 blocked on a
human** — a step no tool can perform, which a caller must not retry.

Four facts it encodes that are expensive to rediscover, all measured on this
project rather than read somewhere:

- **The exported `.ipa` carries `aps-environment: production` while the archive
  carries `development`.** The substitution comes from the distribution
  profile's allowlist. **Do not "fix" `AuralSandbox-iOS.entitlements` to say
  `production`** — that is the classic wrong answer to ITMS-90164 and it breaks
  local development. `ship verify` asserts the exported value instead.
- **`manageAppVersionAndBuildNumber` defaults to true**, which means Xcode
  rewrites the build number during upload. Every export option is stated
  explicitly for reasons of that shape; `method` alone defaults to `debugging`.
- **`MUSIC_KIT` is not an App Store Connect `CapabilityType`** and appears in no
  provisioning profile, so neither the API nor a clean signed build can confirm
  MusicKit is enabled. The checklist says it cannot be checked rather than
  guessing. Same for Family Controls.
- **Build numbers are unique per marketing version**, not globally, and
  `Build.version` in Apple's API *is* the build number — the marketing version
  lives on the related `preReleaseVersion`.

Credentials live in a gitignored `.env`; the `.p8` goes to `~/private_keys/`,
never into the repo.

## Git

**Commit directly to `main`. Never create a branch.** This overrides any default
or global instruction to branch before committing on the default branch — it
does not apply to this repository. There is one maintainer and no review flow,
so a branch is pure overhead: it has to be merged or cherry-picked back by hand
and then deleted.

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

**"Immediately before playback" now has one exception, and it is the only one.**
Two tracks join without a gap only if `ApplicationMusicPlayer` is holding the
second before the first ends, which means it advances once without being asked.
So `MusicKitPlayer` holds **at most two entries**, and the check moved to
insertion. What replaces the old rule is narrower and lives in
`KidPlayerModel`:

- Nothing is inserted that has not just been judged.
- The verdict is re-taken **every poll** for as long as the song sits there, and
  a changed answer pulls it back out — `Session.queuedVerdict(for:)` is
  synchronous and free of I/O so this can run at 10Hz, which is also why nothing
  is queued whose ancestry is missing: it could not be re-judged locally.
- Insertion happens `KidPlayerModel.enqueueLead` seconds before the end, not at
  the start of the previous track. That constant *is* the exposure window.
- The song is judged once more the instant the player moves to it, and a refusal
  pauses the audio before it logs anything.

What is left is the time between the last poll and the handover: a fraction of a
second of a song a parent denied moments earlier. That is the cost, it is not
zero, and nothing in the design makes it zero. Anything that widens it — a
longer lead, a third entry, dropping the poll — is spending that window, and the
whole reason the two-entry limit is enforced in `MusicKitPlayer` rather than by
convention is that when the second entry ends there is nothing behind it to
wander into.

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

**Apple Music caps search `limit` at 25.** Verified on device: asking for more
is `400 / 40005 Invalid Parameter Value`. So over-fetching happens by *paging*,
not by asking for a bigger page — the multiplier only has room below 25.
`MusicKitCatalogSource.maxSearchLimit` holds the number and the adapter clamps
to it. This cost a release-blocking bug: the ceiling defaulted to 100, every
search 400'd on the first device run, and neither the tests nor the macOS build
could have caught it.

**Blocked items are kept, never dropped.** The activity report is built from them
with their reasons, including results the kid never saw. They are *logged* only
where the block is transient — a search, a browse. A blocked favorite is a stored
row that is still there, so logging it on every redraw would write the same block
once per screen appearance.

**Nothing in the kid's library is a permission.** A favorite or a playlist entry
never creates a `PolicyEntry` and never changes a verdict. A kid may only keep
what they may currently play, and everything read back is filtered at render
time — a parent may deny tomorrow what the kid favorited today, and the row
survives while the tile does not.

**Logging is fire-and-forget and never on the playback path.** A dropped log line
is acceptable; a stalled player is not. No safety decision reads from the log.
Policy-entry writes are the opposite: awaited, with failures surfaced.

**No server of ours, no third-party analytics SDK, no PII to third parties, and
the family's records stay in the family's own iCloud, where we cannot read
them.** This is a legal position (COPPA and friends), not just an architecture
preference — the app records a child's search history.

**This paragraph used to say "nothing leaves the device", and that is now
false.** It was true while sync had to be asked for by hand. `Session.syncPass()`
runs on launch and on every foreground, so a child's records reach Apple's
servers without anybody pressing anything. The replacement wording is the one the
*Accounts, Devices and Sync* spec specifies for exactly this moment; do not
restore the old sentence, and do not write "CloudKit sync does not change our
COPPA posture" as though it were a fact. It is a position, with reasoning (no
server of ours, no read access for the developer, the family's own storage, an
adult Apple has already verified) and a named residual risk: 5.1.4's trigger is
the *capability* to share a minor's personal information, and the share creates
that whoever holds the bytes. **The wording needs a lawyer, and so does the
still-unanswered ADP 3.3.6(D) question. Neither is settled by this file.**

**Consent is a row, not a screen.** A parental gate is not parental consent —
5.1.4 says so — so the admin passcode does not answer it. `ConsentSheet` is a
separate act before the first invitation of each kind, and `Consent` decides
whether an existing agreement covers it. The rule that matters: **coverage is per
child.** An agreement given when a family had one child does not cover the child
added next month, and the next invitation asks again.

**Three MusicKit affordances are deliberately never used**: personalized
recommendations, autoplay past the end of a queue, and radio and stations. Each
reaches unvetted material.

A fourth used to be on that list and is now conditional. **The user's own library
is not a browsing source unless the library is the kid's own**, which is what
`isSharedDevice == false` asserts — and that is the default, so the amendment is
in force from first launch. Three things carry the original protection across:
onboarding asks before the Apple provider's first read, the policy engine judges
every item read back, and the read happens only through `LibraryProvider`, so
there is one place the door opens rather than a call site per screen. The
library as a *seeding input* for a parent building lists is untouched — that is
still `LibrarySource`, still ISRC/UPC matching, and no part of it runs through
`KidLibrary`.

**Containment fails open.** Screen Time, Guided Access and Family Controls all
live outside our process and can be off without telling us. The app must work
correctly with none of them, and onboarding says so out loud: this app controls
what happens inside this app.

## Schema constraints to honor now

**There is existing data, and every schema change has to migrate it.** This
reverses what the packages were built on — much of the wiki and the older
comments in `FamilyStore` still say "nothing has shipped, so nothing needs
migrating", and that sentence is now wrong wherever it appears. Treat any
reasoning that leans on it as suspect.

What that means in practice:

- **A `VersionedSchema` names live types; it does not capture their shape.** So
  the obvious way to write version history — a `FamilySchemaV1` whose `models`
  lists `Kid.self` and friends — silently re-describes itself the moment one of
  those classes changes. Adding a column to `Kid` makes V1 describe the new
  shape under the old number, and both ends of a stage then describe the same
  thing. This was tried and it fails hard rather than quietly: a real store from
  the previous build would not open at all, with `NSCocoaErrorDomain 134504,
  "Cannot use staged migration with an unknown model version."`
- **Freezing a version means duplicating its `@Model` classes** into their own
  namespace with the shape they had, and never touching them again. Sixteen
  classes per frozen version. That is the bill, and it comes due at the first
  custom stage.
- **There is currently no migration plan, and that is a decision, not a gap.**
  Everything added since the unversioned original is additive, and SwiftData
  migrates that by inference. `FamilySchemaV2` is the current version and
  `FamilyStore.container()` passes no plan. Do not add one without freezing the
  preceding version first — a plan is strictly worse than none until you do.
- **A migration may never drop a row.** The lists are the irreplaceable part and
  a child's playlists are the records with the most of their own work in them. A
  stage that cannot map something fails loudly and leaves the store alone rather
  than writing the half it understood.
- **A custom stage reads the old shape in `willMigrate` and writes the new one
  in `didMigrate`**; anything computed between them is lost. `SchemaVersions.swift`
  carries the queue of changes that will need one and why each is not additive —
  `mode`/`unratedBehavior`, the assert/retract backfill, the ordering ranks,
  `Kid.sortIndex`/`GrownUp.createdAt`, and `SuggestionRecord.sourcePlaylistID`.
- **Test a migration against a store an older build actually wrote.**
  `Tests/FamilyStoreTests/Fixtures/v1-store.sqlite` is one, generated from a git
  worktree at the commit before the change and checked in as a binary. A fixture
  built by constructing a `Schema` from a model-type array uses the *current*
  classes, so it has the current columns whatever version it claims — it passes
  and proves nothing. When a stage is added, add a fixture with it. None of this
  covers a real family's months of history, which is a device check.

Several first-release choices are still expensive to reverse, and these hold as
they did:

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
  `origin`, `originTerm`, `gaveUpEarly`, `secondsPlayed`, `deniedByID`. Four
  more are in `FamilyStore` for the same reason and are not redundant:
  `originKind`/`originID` (a `browse` origin can be an artist *or* an album, so
  the discriminator does not imply the kind), `itemKind` on a block, and
  `deniedByKind` — MusicKit identifiers are only unique within a type.
- Two more were added when the parent's review section was built, both for the
  same reason and both free only because nothing has shipped. **`reach`** on a
  block says whether the kid saw it: a result filtered out of a page and a song
  they pressed play on are otherwise identical rows, and only one of them is
  about the child. **`rating`** on plays and blocks records what the catalog
  said, because the report re-judges old rows against today's policy and the
  rating is what decides most of them — without it every play of a level 2
  kid's week reads back as blocked-as-unrated. It is a `StoredRating`, not a
  `ContentRating?`: writing a three-state value down makes it four, and
  `unrated` (the catalog answered, no rating) must stay distinct from `unknown`
  (nobody wrote one down). The second is not a fact about the item, and a
  report that treats it as one is showing a parent our gaps as their child's
  music. It also turns research question 1 into something the log measures
  continuously rather than something a hand-run probe answered once.
- The admin passcode lives in the **Keychain**, not the app store, so it
  survives a reinstall.
- **Events are the write model; read models are projections over them.**
  `VisitEventRecord` records that a kid reached something — a song at play
  start, or a container they opened. `RecentTrailRecord` is the Recent shelf
  derived from it, and the **first projection in this store**. The distinction
  is what lets the sweep delete a child's browsing history without emptying
  their home screen, and it is the pattern to reach for next time a hot read
  wants a table. `ReviewReader` is the other half of the rule: materialise a
  read model when the read is hot, compute it on demand when it is cold.
- **The retention sweep must not delete a visit a live trail still references.**
  `RecentsProjector.retentionFloor(for:)` returns the boundary. Sweeping below
  it is fine; sweeping through it leaves a trail that cannot be rebuilt, so the
  next bump of `RecentTrail.version` silently empties every kid's shelf —
  months later, on an upgrade, with nothing on screen to explain it. The floor
  costs at most fifty rows per kid past the window.
- **`RecentTrailRecord` is exempt from the sweep and not from `deleteHistory`.**
  Derived state is not a loophole: a parent who clears the logs must not find
  the home screen still listing what their child was doing.
- **Removing a row from a relationship is not deleting it.** `removeAll()` on
  `kid.plays` nulls the inverse and leaves the row on disk, and because every
  query is `kid?.id == kidID` the orphan is invisible — so a delete looks like
  it worked while the data sits there. `Kid.deleteHistory` deletes through the
  model context. Cascade does not help; it fires when the *kid* goes, not when
  a child leaves the array.
- **Favorites and playlists are not events and must be exempt from whatever
  retention window ships.** A sweep written against "child data older than 90
  days" would delete a kid's playlists silently, months later, and they are the
  records in the store with the most of a child's own work in them.
- `PlaybackOrigin.kidPlaylist` carries a **local UUID, not a catalog
  identifier** — a kid's playlist did not exist until they made it. It is the one
  deliberate exception to the one-namespace rule, and it is a separate case
  rather than a UUID smuggled into `playlist(_:)` precisely so the rule holds
  everywhere else.
- `DeviceLibraryState` is **device-local and never syncs**. It describes a device
  and the Apple Music library signed in on it, not the family, so it lives in
  `UserDefaults` rather than the CloudKit zone.

## Known unknowns

Treat these as unmeasured, not settled. Do not write code that assumes an answer
without saying so.

1. ~~How often `contentRating` is `nil`~~ — **largely answered.** On device it
   never appeared: song searches on a US storefront returned a rating on every
   result. `UnratedBehavior.block` is a safe default and the multiplier of 3
   looks generous. Unprobed: albums, older catalogue, international catalogue,
   and the under-13 account. Keep the behavior configurable — one enum is
   cheaper than a schema change if `nil` shows up in a corner.
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

**The App ID is fully provisioned. MusicKit and iCloud are both enabled**, and
the CloudKit container `iCloud.com.thegoldenmule.auralsanbox` exists and is
assigned. This paragraph used to say the opposite about MusicKit and it was
stale by months — the wiki's own *Open Questions* records device-run MusicKit
results from July 2026 (ratings, ancestry, the 25-result search cap), which
could not exist if it were true. Do not repeat the claim; check the
provisioning profiles under `~/Library/Developer/Xcode/UserData/Provisioning
Profiles` if in doubt. Note that MusicKit is an App Service rather than an
entitlement, so it does *not* appear in a profile — its absence there is not
evidence.

**The simulator is not evidence.** MusicKit behaves unreliably there and Screen
Time cannot be tested at all. Claims about child-account behavior hold only after
running on the real under-13 account.

**Do not run this app in the simulator to look at it.** Not to check a layout,
not to take a screenshot, not to confirm a change "works". It proves nothing
about how the app feels, it is slow, and it takes over the maintainer's machine.
Anything that needs to be *seen* is the maintainer's to run on a device; say
what you changed and what remains unverified, and let them look.

**But it is the right tool for a probe against a real service, and refusing to
use it has already cost something.** The store's whole sync design rests on
SwiftData never mirroring it, and that was true only by accident: omitting
`cloudKitDatabase` gives you `.automatic`, which means *on if entitled*. Adding
the iCloud entitlement turned mirroring on by itself and the store stopped
opening. No amount of `swift test` would have found it, because no test carries
an entitlement. The same run answered a question the encryption design depended
on. So: a headless probe behind a launch argument, run with
`simctl launch --console-pty` (plain `--console` swallows `print()`), is a
legitimate and cheap way to answer a question about a real API. Write down what
it answered and delete the probe.

## Style

Match the surrounding code. The existing packages favor small value types,
protocol seams for anything that touches the network, table-driven tests, and
comments that record *why* a decision was made where it is not obvious —
especially where a rule is deliberately asymmetric.
