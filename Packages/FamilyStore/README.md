# FamilyStore

Where a family, their kids, those kids' walls, and those kids' history live.
SwiftData, local only, no server of ours.

Depends on `PolicyEngine` and nothing else. Deliberately **not** on `CatalogKit`
— catalog metadata arrives as values a caller passes in, so this package builds
and tests on any machine with no MusicKit, no subscription, and no device.

```swift
let context = ModelContext(try FamilyStore.container())
let kid = Kid(name: "Robin", mode: .denyPlusAuto)

kid.addEntry(kind: .deny, id: badBand, displayName: "A Band")
try context.save()          // awaited; a failure here must reach the parent

let engine = kid.makeEngine()

let log = EventLog(modelContainer: container)
log.log(playEvent, for: kid.id)   // fire and forget; never on the playback path
```

## Shape

| Type | Job |
| --- | --- |
| `FamilyStore` | The schema, and how to open it. |
| `Family`, `Kid` | The household and the kids in it. |
| `PolicyEntryRecord` | One allow or deny row. |
| `SearchEventRecord`, `PlayEventRecord`, `BlockEventRecord` | The log. |
| `WeeklySummaryRecord` | Empty at v1. See below. |
| `EventLog` | A `@ModelActor` that writes events off the caller's thread. |
| `SearchEvent`, `PlayEvent`, `BlockEvent` | The `Sendable` values that cross into it. |

## Two write contracts, on purpose

They are opposites, and the asymmetry is the whole design.

**Policy entries are awaited and their failures surfaced.** A parent who taps
deny and gets silence must not be left believing the deny landed. Entries are
added on the main context and the caller saves and shows the error.

**Events are fire-and-forget and never awaited.** A dropped log line costs a
report one row. A stalled player costs a kid their music. Nothing that decides
what a kid may see or play ever reads from the log, so losing a row costs safety
nothing. `EventLog.log(_:for:)` returns immediately and swallows failures;
`record(_:for:)` throws and exists for tests and for surfaces that genuinely
need to know.

## Reading a policy back

`Kid.buildPolicy()` is the one read on the hot path. `mode` and
`unratedBehavior` are used exactly as stored — no default is substituted here or
anywhere below. That is why they are columns rather than constants: changing a
recommended default in a later release must not silently change what an existing
kid can reach.

**Unreadable rows fail closed.** A row whose `kind` string does not read back,
but whose identifier still parses, is used as a **deny**. A phantom deny hides
one item a parent meant to allow — visible, and fixable in one tap. A dropped
deny silently unblocks something a parent explicitly refused. A row whose
`itemKind` does not parse cannot become a `CatalogID` at all and is dropped.
Either way the row's id comes back in `PolicyBuild.unreadableEntryIDs` so the
admin can say what it could not read, rather than starting quietly wrong.

In practice these strings are written by our own code from typed enums, so a row
lands there only through corruption or a schema we did not anticipate.

## Columns that exist because they cannot be added later

A fact nobody wrote down at v1 is absent from that period forever — no later
release can backfill it. Five such fields were named in the spec: `origin`,
`originTerm`, `gaveUpEarly`, `secondsPlayed`, `deniedByID`. All are here.

**Four more are here that the spec's schema did not name.** Each is one column
now and impossible later:

- `originKind` and `originID` on plays and blocks. The spec stored `origin` and
  `originTerm`, which reconstructs `home` and `search` and loses the identifier
  on `browse` and `playlist`. `browse` can be an artist *or* an album, so the
  kind cannot be inferred from the discriminator either.
- `itemKind` on `BlockEventRecord`. A block lands on any of the four kinds, and
  MusicKit identifiers are only unique within a type — an identifier without its
  kind is ambiguous across them.
- `deniedByKind`, for the same reason as `deniedByID`.

`WeeklySummaryRecord` is also here and nothing writes to it. Summaries are
derived on read while their events exist; this table is only what survives the
retention sweep. It is at v1 so that the release which finally decides the
retention window is not also the release that introduces the table. Its payload
is an opaque blob because the summary's shape is the part most likely to change
once a parent has actually read one.

## Sync compatibility, paid before there is data

v1 is local-only, but the schema is already shaped for the custom-zone share the
family model needs in v2:

- Stable `UUID`s generated at creation, never derived from position or content.
- `modifiedAt` on every record, stamped by mutators rather than left to callers
  — every stored property is `private(set)` so there is no way around them.
  Attaching an event deliberately does *not* stamp the kid: that field is what
  an entry-level merge will compare, and a child listening to music should not
  look like a parent editing settings.
- Nothing depends on insertion order or locally sequential identifiers.
- Every attribute has a default and every relationship is optional, which
  CloudKit requires.
- No `@Attribute(.unique)` anywhere — CloudKit rejects unique constraints
  outright.

**The custom zone itself is not settled.** The spec's invariant is a *named*
custom zone from the first release. SwiftData does not expose zone naming; its
CloudKit integration uses one fixed custom zone. That satisfies *not the default
zone*, which is where the migration risk actually lives — but whether that zone
can be shared wholesale with `CKRecordNameZoneWideShare` is unverified, and the
answer decides whether sharing stays on SwiftData or drops to
`NSPersistentCloudKitContainer`. That is Storage Stage 4, and it is not answered
by this package compiling. See `FamilyStore.zoneNote`.

## Tests

33 tests in 11 suites, in-process, no device.

```sh
swift test
```

The Stage 1 exit test is `Relaunch` — a kid, a list and a session's events
survive closing and reopening a real on-disk store, with the engine built from
stored values. The other half of that exit test, that records sit in a custom
zone, **cannot be checked here**: there is no CloudKit container attached in v1,
so there is no zone to inspect.

## What is not here

Retention, the launch sweep, summary derivation, delete-everything across a
family, and anything to do with CloudKit. Retention in particular is blocked on
a decision, not on code: ninety days rolling into summaries versus keeping
everything until a parent deletes it. Shortening a window later destroys data a
parent relied on, so the window gets chosen in writing before the sweep is
written.

`Kid.deleteHistory()` is here, because delete-has-to-mean-delete is a property
of the schema rather than of the sweep: it takes summaries as well as raw
events, and leaves lists and mode alone. Curation is not history.
