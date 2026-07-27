# Spec: Storage and Data Model

**Status:** restated

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

## Review
_Not reviewed._

## Open notes
_None._
