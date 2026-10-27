# Storage and Data Model

**Status:** restating

## Sections
### Motivation
We need to store data carefully because of child data laws.

### Overview
SwiftData, no server of our own. A family holds kids; each kid holds their policy entries and their events.

**v1 is local only.** Nothing leaves the device.

**Sharing within the family's iCloud is a requirement, not a maybe.** A family's data has to reach every parent's device, and those are different Apple Accounts, so plain iCloud sync cannot carry it. The mechanism is a custom CloudKit record zone in the private database, shared zone-wide, with the family members as participants.

That has one consequence v1 cannot defer: **records go in a custom zone from the first release.** The default zone cannot be shared at all, so writing there now means migrating every record later.

Allow and deny are one type with a flag. Display names and artwork URLs are copied onto entries and events rather than referenced, so the admin renders offline and a delisted item still reads as a name.

### Data model & types
```swift
@Model final class Family {
    var id: UUID
    var modifiedAt: Date
    @Relationship(deleteRule: .cascade) var kids: [Kid]
}

@Model final class Kid {
    var id: UUID
    var modifiedAt: Date
    var name: String

    /// Stored explicitly, never read from a global default at evaluation time.
    var mode: SandboxMode
    var unratedBehavior: UnratedBehavior

    @Relationship(deleteRule: .cascade) var entries: [PolicyEntryRecord]
    @Relationship(deleteRule: .cascade) var searches: [SearchEventRecord]
    @Relationship(deleteRule: .cascade) var plays: [PlayEventRecord]
    @Relationship(deleteRule: .cascade) var blocks: [BlockEventRecord]
    @Relationship(deleteRule: .cascade) var summaries: [WeeklySummaryRecord]
}

/// `catalogID` is always an Apple Music catalog identifier. Library identifiers
/// are resolved before they reach here and never stored.
@Model final class PolicyEntryRecord {
    var id: UUID
    var modifiedAt: Date
    var kind: String              // "allow" | "deny"
    var itemKind: String          // artist | album | playlist | song
    var catalogID: String
    var displayName: String       // copied at add time; survives delisting
    var artworkURL: URL?          // reference only; the image is never copied in
    var addedAt: Date
    var addedBy: String?          // nil until there is more than one parent
}

@Model final class SearchEventRecord {
    var id: UUID
    var at: Date                  // device clock
    var term: String
    var resultCount: Int
    var blockedCount: Int
    var gaveUpEarly: Bool
}

@Model final class PlayEventRecord {
    var id: UUID
    var at: Date
    var songID: String
    var albumID: String?          // nil when lineage never resolved
    var artistID: String?
    var displayName: String
    var secondsPlayed: Int        // under 5 is never written
    var origin: String
    var originTerm: String?       // the search term, when origin is search
}

@Model final class BlockEventRecord {
    var id: UUID
    var at: Date
    var itemID: String
    var displayName: String
    var artistID: String?
    var reason: String            // includes restrictedOutsideApp
    var deniedByID: String?       // which entry matched, for deniedByParent
    var origin: String
}

/// Persisted only once its events are swept away.
@Model final class WeeklySummaryRecord {
    var id: UUID
    var weekStart: Date
    var payload: Data
}
```

### Algorithm
**Building an engine for a kid.** The one read on the hot path.

```text
1. map kid.entries to PolicyEntry(kind, CatalogID(itemKind, catalogID))
2. Policy(mode: kid.mode, entries:, unratedBehavior: kid.unratedBehavior)
   both stored values are read as-is; no default is substituted
```

**Writing an event.**

```text
1. hand to a background context; do not await on the caller
2. on failure, drop it
```

**Retention sweep.** On launch, before any report renders.

```text
1. cutoff := now - detailWindow
2. for each week entirely older than cutoff:
     compute and persist its summary
     delete that week's search, play and block rows
3. leave a week straddling the cutoff whole
```

**Delete everything.**

```text
1. delete searches, plays, blocks
2. delete summaries too — a summary outliving its events is a record the parent
   asked us to destroy
3. keep the kid, their mode and their lists; curation is not history
```

### Invariants & limits
- Every record carries a stable UUID generated at creation, never derived from position or content.
- Every record carries `modifiedAt`, written on every change.
- Nothing depends on identifiers being locally sequential or on insertion order.
- All records live in a named custom zone, never the default zone, from the first release.
- `mode` and `unratedBehavior` are stored per kid. No code path substitutes a global default at read time.
- Every stored `catalogID` is an Apple Music catalog identifier.
- Allow and deny live in one table, distinguished by `kind`.
- `displayName` is captured at write time.
- `artworkURL` is a reference; artwork bytes are never copied into our storage.
- Events are written off the playback path.
- A play under five seconds is never written.
- Summaries are derived on read while their events exist, and persisted only when those events are swept.
- Deleting a kid's history deletes their summaries.
- Deleting a kid's history does not touch their lists or their mode.
- In v1 nothing in this store leaves the device.
- The zone is shared wholesale. CloudKit has no per-record access control inside a shared zone, so who sees what is decided by the app, not by the store.

### Failure & concurrency semantics
**Write failure on an event: drop it.** Logging is fire-and-forget and never awaited on the playback path. No safety decision reads from the log.

**Write failure on a policy entry: surface it.** A parent who taps deny and gets silence must not believe the deny landed. List writes are awaited and their failures shown.

**Partial data on events.** `albumID` and `artistID` are nil when an item was judged before lineage resolved. Those rows count toward totals but cannot be grouped by artist.

**Device clock.** Timestamps use device time, which a kid can change. Weekly bucketing is approximate.

**Store corruption or a failed migration.** The lists are the irreplaceable part; history is merely useful. Preserve entries at the cost of events, and say what was lost rather than starting silently empty.

**Concurrency in v1.** One writer: the active kid's session. Events go through a background context, the admin writes on the main context.

**Concurrency once shared.** Two parents editing one kid's list from two devices is a real conflict, and last-write-wins over a whole list would silently discard someone's curation. Entry-level merge — treating the list as a set of independently added and removed rows rather than one value — is the shape that survives it. Settle that before sharing ships.

**View gating is a product control, not a security boundary.** Every participant's device holds the whole zone, so the app deciding what to show them is a UI decision about what is useful, not an access control. Anything that genuinely must not reach another parent cannot go in the shared zone at all.

**A participant leaving the share.** Their device keeps whatever it last synced. There is no remote wipe, so removing a parent from the family is not the same as removing their copy.

### Data dependencies
This is the layer everything else reads from, so its own dependencies are few.

**Catalog metadata copied in at write time** — `displayName` and `artworkURL` from CatalogKit when an entry is added or an event recorded. That is the only moment they are free. They are never refreshed, so a renamed album keeps the name it had. Freshness traded for availability.

**Verdict reasons at judgement time** — captured then, because the policy that produced a reason may have changed by the time anyone reads the report.

**The Keychain** — holds the admin passcode, deliberately outside this store so it survives a reinstall.

**The device clock** — not trustworthy.

**An iCloud account, once sharing is on** — not needed in v1, and not a hard requirement afterwards either. A family with no iCloud account, or one that declines the share, keeps a working local-only app. Sharing is additive, never a precondition for the app functioning.

### Migration & existing data
**No data exists.** This is about making the first schema the one that does not need rewriting.

**The zone is the decision that cannot wait.** CloudKit cannot share the default zone, so records have to live in a named custom zone before sharing is possible. v1 does not sync, but it writes into that zone anyway. Writing to the default zone now and moving later means rewriting every record in every install, which is the expensive kind of migration and the one most likely to lose data.

**Sync compatibility, paid for now.** Stable UUIDs, `modifiedAt` everywhere, no reliance on local ordering, and the family as an explicit record with its own id.

**No scope discriminator.** An earlier design had library and catalog identifiers coexisting, which would have needed a scope field on every entry and a migration when the rule changed. Resolving library picks to catalog items removed the axis.

`mode`** and **`unratedBehavior`** are stored, not defaulted.** If either is absent and a constant is consulted at evaluation time, changing a recommended default silently changes what every existing kid can reach.

**Event fields absent at v1 are absent forever for that period.** `origin`, `originTerm`, `gaveUpEarly`, `secondsPlayed` and `deniedByID` each cost a column now.

**Whatever the app uses to gate viewing needs its field at v1 too.** Which participant a record belongs to, or which parent may see a given kid, is app-layer and not yet designed — but if it turns out to be a column, adding it after there is shared data is a migration across accounts rather than one device.

**The retention window is unresolved.** Ninety days rolling into summaries, versus keeping everything until deletion. Shortening a window later means destroying data a parent relied on.

### Staged plan
**Stage 1 — the schema, in a custom zone, local only.**

- Ships: the full model including columns nothing reads yet, written into a named family zone with no CloudKit container attached.
- Does not: sync, share, retention, summaries, on-disk catalog cache.
- Exit test: a kid, a list and a session's events survive a relaunch; the engine builds from stored values with no default substituted; and the store file shows records in the custom zone, not the default one.

**Stage 2 — reads that hold up.**

- Ships: the admin list rendering from stored names and artwork URLs, and the reports screen reading events.
- Does not: derive summaries.
- Exit test: the allow list renders fully in airplane mode.

**Stage 3 — summaries and retention.**

- Ships: summaries derived on read, the launch sweep, persisted summaries for swept weeks, delete-everything covering both.
- Does not: ship before the retention window is decided in writing.
- Exit test: events past the window are gone, summaries survive, delete-everything leaves nothing — verified by inspecting the store file.

**Stage 4 — prove zone-wide sharing.**

- Ships: a throwaway project sharing a custom zone between two Apple Accounts using `CKRecordNameZoneWideShare`, with a real share-acceptance flow.
- Does not: touch the shipping app. The open question is whether SwiftData's CloudKit integration will share the zone it manages, or whether we have to drop to `NSPersistentCloudKitContainer` or hand-rolled CloudKit.
- Exit test: a record written on one account appears on the other, and the answer to that question is written down.

**Stage 5 — family sharing, for real.**

- Ships: the family zone shared with the other parent's account, entry-level merge on lists, and explicit consent at the moment sharing is turned on.
- Does not: ship on last-write-wins over whole lists, and never makes sharing a precondition for using the app.
- Exit test: two parents edit the same allow list from two devices while offline; both reconnect; neither one's additions are lost.

### Found while building it
`FamilyStore` implements Stage 1. Five things came out of writing it that the spec above does not say, and each is the kind of thing that is cheap now and impossible later.

**Four columns beyond the schema.** The spec names five fields that cost a column now and are absent forever if added later: `origin`, `originTerm`, `gaveUpEarly`, `secondsPlayed`, `deniedByID`. Four more belong on that list for exactly the same reason.

- `originKind` and `originID` on plays and blocks. `origin` plus `originTerm` reconstructs `home` and `search` and loses the identifier on `browse` and `playlist`. A `browse` origin can be an artist _or_ an album, so the kind cannot be inferred from the discriminator either.
- `itemKind` on `BlockEventRecord`. A block lands on any of the four kinds, and MusicKit identifiers are only unique within a type — an identifier without its kind is ambiguous across them. This is the same reasoning `CatalogID` already encodes everywhere else.
- `deniedByKind`, alongside `deniedByID`, for that same reason.

**Unreadable policy rows fail closed.** The spec does not say what happens when a stored `kind` or `itemKind` string does not read back. The rule implemented is asymmetric on purpose: a row whose `kind` is unreadable but whose identifier still parses is used as a **deny**, not dropped. A phantom deny hides one item a parent meant to allow — visible, and fixable in one tap. A dropped deny silently unblocks something a parent explicitly refused. A row whose `itemKind` is unreadable cannot become a `CatalogID` at all and is dropped. Either way the row's id is returned alongside the policy so the admin can say what it could not read, rather than starting quietly wrong.

**The named custom zone is not achievable as worded.** The invariant asks for records in a _named_ custom CloudKit zone from the first release. SwiftData does not expose zone naming — its CloudKit integration uses one fixed custom zone. That still satisfies _not the default zone_, which is where the migration risk actually lives, so the expensive part of the invariant holds. What remains unproven is whether that zone can be shared wholesale with `CKRecordNameZoneWideShare`, which is what Stage 4 exists to answer. A local-only v1 compiling proves none of this.

`modifiedAt`** is enforced structurally, not by discipline.** Every stored property is `private(set)` and changes only through mutators that stamp it. Leaving properties writable would make the invariant something each caller had to remember, and entry-level merge later depends on it being true. Attaching an event deliberately does _not_ stamp the kid: that field describes the kid record itself, and a child listening to music should not look like a parent editing settings on the one record sync most needs to be quiet.

**CloudKit's own constraints are paid now.** No `@Attribute(.unique)` anywhere — CloudKit rejects unique constraints outright. Every attribute carries a default and every relationship is optional, which CloudKit requires. That forces a default onto `mode` and `unratedBehavior`, which sits awkwardly against the invariant that they are never defaulted at read time. The resolution: the initializer always supplies both, so no real row falls back, and the schema defaults are the _most restrictive_ values rather than the recommended ones — `allowOnly` and `block` — so that if one ever were consulted it would fail closed.

### Found while building the parent's library editor
Letting a parent manage a kid's favorites and playlists directly turned up two storage facts. Both are the same shape as the four columns above: cheap while nothing has shipped, expensive once two parents' Apple Accounts share a family zone.

`LibraryOrigin`** needs a third case, and the precedence between them is the real decision.** The enum was `kid` and `appleLibrary` — what the child chose against what arrived with the account. A parent placing something on a shelf is neither, and stamping it `kid` makes the report say the child chose something a parent picked. `parent` was added, and with it an ordering, because `FavoriteRecord.refresh` has to decide which claim survives when the same favorite arrives twice:

`kid`** > **`parent`** > **`appleLibrary`**.**

- `kid` on top for the original reason: a row the child chose never degrades. A parent re-placing something the kid already favorited leaves it the kid's.
- `parent` above `appleLibrary` because both are "not the child" but only one of them is a person who _decided_. Adoption is an automatic side effect of a library read, so if it could overwrite, the Apple provider's first pass would silently relabel every parent-placed row as "already in the library".
- A row whose stored origin the running build cannot read has no claim to protect, so any real origin overwrites it. This is the one place `libraryOrigin == nil` means something other than "drop this row".

The rule lives in exactly one place. In particular `MergedLibrary.mergedFavoriteRows()` is a first-writer-wins union that never inspects `origin`, and the Stage 3 adoption pass must write through `Kid.addFavorite(origin:)` rather than comparing origins at merge time — a second copy of the ordering is the one that would drift.

The read side has to keep the distinction too: `ReviewedLibrary.adopted` means "arrived with an account" and nothing else, with `placedByParent` as a separate property. The tempting later edit is to redefine `adopted` as "not chosen by the kid", which would fold a parent's own decisions in and report them back as the account's doing.

**Playlist entries needed the same column.** `PlaylistEntryRecord` had no origin, so a song a parent added to a child's playlist was indistinguishable from one the child added — and "you added 4 of these 12" would have been a migration rather than a caption. It falls back to `kid` on an unreadable value rather than dropping the row, deliberately unlike `FavoriteRecord`: a dropped entry silently shortens a playlist a child built, which is worse than one row attributed to the commonest case.

**The forward-compatibility cost of the drop-it path, stated plainly.** `FavoriteRecord.row` returns `nil` for an origin the running build cannot read, and `CloudKitLibraryProvider.favorites()` does `compactMap(\.row)`. So a favorite written by a _newer_ build carrying a fourth case is **invisible** on an older one — not mislabelled, gone: no tile, empty heart. Re-favoriting on the old build hits the upsert and overwrites the newer origin with `kid`. Today that is unreachable, since nothing syncs. Under v2's shared family zone it is a real cross-version scenario, and `parent` is the last case that can be added for free.

### Found while planning multi-adult sync
The sharing design lives in **Accounts, Devices and Sync**. Four things it settled belong here, because they are about this store rather than about accounts.

**Stage 4's probe is retired, and the answer changes the transport.** SwiftData's `CloudKitDatabase` has exactly `automatic | private(_:) | none` — there is no shared-database store scope. So a second parent's device could never _read_ the share through SwiftData mirroring, whatever the owner side can do, and the zone-wide-share question that Stage 4 existed to answer is moot. The decision taken instead: **do not mirror the store at all.** `FamilyStore.container()` keeps no CloudKit container forever, and a new `Packages/FamilySync` owns the `CKRecord` mapping and two `CKSyncEngine` instances. SwiftData stays the authority; CloudKit becomes a transport over it. `zoneNote` should be rewritten to say this rather than to pose the question.

**Stage 5's "entry-level merge" now has a mechanism, and it is a schema change.** Treating a list as a set of independently added and removed rows requires the removal to be a _row_, not an absence. `PolicyEntryRecord` gains `assertedAt` and `retractedAt`, live iff `assertedAt > retractedAt`, with every read filtering and removal stamping rather than detaching. Inside a 120-second skew window a `.deny` resolves live and an `.allow` resolves retracted — the same fail-closed asymmetry as `UnratedBehavior.block`, one level up. This is also the fix for `Kid.removeEntry` (`Kid.swift:155`), which is `entries.removeAll` with no context delete: exactly the trap the _Removing a row from a relationship is not deleting it_ rule names, and which `removeSuggestion` (`:255`) already got the fix for.

**Two more columns join the cheap-now-impossible-later list, and they are the two most safety-critical fields in the store.** `mode` and `unratedBehavior` are the only enums here stored as typed values with no defensive read — contrast `PolicyEntryRecord.entry`, `BlockEventRecord.event`, `FavoriteRecord.row`, `SuggestionRecord.target` and `RecentTrailRecord.entry`, all of which return `nil` on an unreadable raw value and have a named failure policy. Worse, they sit as attributes on the same record as `name`, so under any whole-record merge a concurrent rename and a mode change resolve as last-write-wins and **the tightening vanishes with no UI trace.** They should become an append-only `SandboxSettingRecord` resolved strictest-wins, with `Kid` keeping a denormalised copy that is never the authority. That also gives the admin something honest to show: _"You set Level 1 at 16:02; Dad set Level 2 at 16:05."_

**Two invariants above need qualifying once there is a second device.**

- _Deleting a kid's history_ is currently an **absence that has to win a race.** A device offline for a week imports the deletions and then exports the rows it wrote while offline, which land after them; and `RecentsProjector.trail(for:)` is documented as always recomputed and saves unconditionally on every launch, so the lagging device rebuilds the shelf from its still-present visits and writes it back. A parent is told the data is gone while their child's home screen lists what they were doing. It needs a `HistoryClearRecord` watermark, applied idempotently and independent of arrival order.
- _The retention sweep_ needs **a single named owner and a lease.** A bulk mutation with no idempotence story and no owner is a sync design question, not a retention one: two devices both sweeping means the same thousands of rows are deleted twice and the loser's delete lands against records already gone. It must also be two-phase and ordered — the `WeeklySummaryRecord` written and confirmed _before_ the rows it covers are deleted, never in one operation. And `WeeklySummaryRecord` has to **sync**, unlike the other two projections: it is what survives the sweep, so a device-local summary means the co-parent permanently loses every swept period.

### Correction: there is existing data, and it has to migrate
**The Migration & existing data section above is wrong now, and so is every argument in this workspace that rests on it.** It opens _"No data exists. This is about making the first schema the one that does not need rewriting"_, and the staged plan, the cheap-now-impossible-later lists, and the sync amendment were all written under it. There is existing data. Every schema change from here migrates it.

The sentence to distrust, wherever it appears: _"nothing has shipped, so nothing needs migrating."_ It is in this page, in **Accounts, Devices and Sync**, and in `CLAUDE.md`. `CLAUDE.md` has been corrected; these pages have not, which is what this section is for.

**What is already done about it.** `FamilyStore` now opens through a versioned schema and a migration plan: `FamilySchemaV1` holds the model list, `FamilyMigrationPlan` carries a store forward, and `FamilyStore.container()` goes through it. `MigrationTests` writes a store in the pre-version shape — a bare `Schema` from a model array, no plan, exactly what older builds wrote — and re-opens it under the plan, asserting the household, the kid, their `mode` and `unratedBehavior`, their policy entries and a playlist with its songs all survive. That passes. It is not a device.

**Why the version stamp went in before any column.** A store opened without a plan records no version, so the first migration has no `fromVersion` to name. Introducing the identifier while the model set is still byte-identical to what is on disk is a no-op re-open that leaves a stamp behind, and it is the only moment it costs nothing. Adding a column first and versioning afterwards is the same work with a migration already owed.

**Three rules that now bind everything in the pay-now list.**

- **A version's **`models`** list is frozen** once a store has been written with it. The sync columns belong to a V2; editing V1 in place leaves both ends of a stage describing the same thing, which is a migration plan that compiles, runs, and does nothing.
- **A migration may never drop a row.** The lists are the irreplaceable part and a child's playlists are the records with the most of their own work in them. A stage that cannot map something fails loudly and leaves the store alone rather than writing the half it understood — the same asymmetry this page already applies to an unreadable policy row.
- **A custom stage reads the old shape in **`willMigrate`** and writes the new one in **`didMigrate`; anything computed between them is lost.

**What this costs the plan.** Most of the pay-now list is additive and migrates lightly — new columns with defaults, new record types. Three items are not, and they need custom stages written and tested before they land:

- `mode` and `unratedBehavior` moving off `Kid` onto `SandboxSettingRecord`. These are the two fields that decide what a child can reach, so a stage that defaults them widens a sandbox with nothing on screen to say so. It carries the stored value across or it fails.
- `PolicyEntryRecord` gaining `assertedAt`/`retractedAt`. Every existing row is live and must backfill to `assertedAt = addedAt`, `retractedAt = .distantPast`. A backfill that gets this backwards retracts a family's entire allow list at once.
- Replacing the three `position: Int` counters with a rank. Existing playlists have contiguous positions that must map to ranks preserving their current order — a child's playlist reordering itself during an upgrade is the visible failure, and there is no undo.

The framing that changes: the reason to pay for a column now was _"free today, impossible later."_ It is now _"a lightweight migration today, a custom one later"_ — still strongly worth doing early, and no longer free.

### Verified: what a SwiftData schema version actually is
A measured fact, not a plan. It came out of building the additive half of the sync schema and it cost a design that had already been committed.

**A **`VersionedSchema`**'s **`models`** list names live types. It does not capture their shape.** So the obvious way to write version history —

```swift
enum FamilySchemaV1: VersionedSchema {
    static var models: [any PersistentModel.Type] { [Kid.self, /* … */] }
}
```

— is a declaration that **silently re-describes itself every time one of those classes changes.** Add a column to `Kid` and V1 now describes the new shape under the old version number. Both ends of a `MigrationStage` then describe the same thing.

**Verified failure mode.** A real store written by the previous build, opened against a plan whose V1 pointed at the mutated classes:

```text
NSCocoaErrorDomain 134504
Cannot use staged migration with an unknown model version.
```

The store's recorded version matched nothing the plan could describe, so there was no path from it and **the store would not open at all**. That is the good outcome — it fails loudly rather than migrating something into a shape nobody intended.

**Freezing a version means duplicating its **`@Model`** classes** into a namespace of their own, with the shape they had, and never touching them again. Sixteen classes and their initializers per frozen version. That is the real cost of staged migration in SwiftData and it should be priced into any plan that assumes versioning is bookkeeping.

**What is in the code now.** No migration plan at all, and that is a decision rather than a deferral. Everything added so far is additive — new entities, and columns whose defaults are the truthful value for a row that predates them — and SwiftData migrates that by inference with no plan and no frozen copies. `FamilySchemaV2` is the current version; `FamilyStore.container()` passes no plan; there is deliberately no `FamilySchemaV1` type, because it could only be a list of live classes. **A plan is strictly worse than no plan until the freeze is paid for.**

**The second half of the lesson is how to test one.** A fixture built by constructing a `Schema` from a model-type array uses the _current_ classes, so it carries the current columns whatever version it claims — it passes, it looks like it proves the migration works, and it proves only that V2 opens V2. The first version of these tests did exactly that. What replaced it is a store file an older build actually wrote, generated from a git worktree at the commit before the change and checked in as a binary (`Tests/FamilyStoreTests/Fixtures/v1-store.sqlite`). Confirmed against it with `sqlite3`: `ZKID` genuinely has no `ZBOUNDACCOUNTRECORDNAME` column. **When a stage is added, add a fixture with it** — the same trick works every time, and each fixture keeps testing every later migration in the chain.

What none of this covers is a store carrying a real family's months of history, which stays a device check.

### Verified: not attaching a CloudKit container is not the default
A measured fact about this store specifically, and the second time this workspace has recorded one that only appeared when something was actually run.

`ModelConfiguration`**'s **`cloudKitDatabase`** parameter defaults to **`.automatic`**, and **`.automatic`** means ****_on if the app is entitled_**** — not ****_off_****.**

The `zoneNote` in `FamilyStore.swift` has always said "v1 is local-only with no CloudKit container attached", and it was true. It was true for the wrong reason: the app carried no iCloud entitlement, so `.automatic` resolved to nothing. Nothing in the code was asking for a local-only store.

Adding the entitlement — which the sharing work requires — flipped SwiftData into CloudKit mode by itself, and the store stopped opening at all:

```text
NSCocoaErrorDomain 134060
CloudKit integration requires that all relationships be optional,
the following are not:
  Family: grownUps, Family: kids
  Kid: blocks, Kid: entries, Kid: favorites, Kid: libraryIndex,
  Kid: playlists, Kid: plays, Kid: recentTrail, Kid: sandboxSettings,
  Kid: searches, Kid: suggestions, Kid: summaries, Kid: visits
  PlaylistRecord: entries, SuggestionRecord: entries
```

`FamilyStore.container()` and `inMemoryContainer()` now pass `cloudKitDatabase: .none` explicitly. That is not a formality: it is the difference between a decision and a coincidence, and the coincidence was going to expire on the day the entitlement landed.

**The error's contents are the second fact, and it corrects something this page says.** _Invariants & limits_ and the _Found while building it_ section both record that CloudKit's constraints are paid — no unique constraints, every attribute defaulted, every relationship optional. The last of those is only half true. **The inverses are optional (**`kid: Kid?`**); the to-many arrays are not (**`entries: [PolicyEntryRecord] = []`**), and CloudKit requires both.** Sixteen relationships are affected, listed above.

They are deliberately **not** being changed. Nothing wants mirroring — the sync design uses CloudKit as a transport over an unmirrored store, on purpose — so making them optional would be paying for a path already decided against, and it would push `nil` handling into every read of every relationship in the store. But it is a schema change, so it is cheap now and a migration later, and it is the price of entry if mirroring is ever reconsidered. Anyone who reaches for `cloudKitDatabase: .automatic` as a shortcut should read this paragraph first.

## Review
_Not reviewed._

## Open notes
_None._
