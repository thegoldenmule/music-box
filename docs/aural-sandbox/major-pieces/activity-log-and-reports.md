# Spec: Activity Log and Reports

**Status:** restating

## Sections
### Motivation
Screen Time's music restriction tells a parent nothing. There is no record of what a kid searched for, played, or tried to reach and could not.

Without that, we have no feedback loop. A parent sets walls once and never learns whether or not they are in the right place.

Recording it means holding a child's browsing history, which brings COPPA and a growing set of state and international law into scope.

### Overview
Every search, play, and block is recorded on the device and rolled up into a weekly summary. The raw log stays available on-device or in an iCloud account.

It runs in all three modes.

Blocks are valuable data. They are how a parent learns their kid is curious about something, so they are kept with their reason, grouped by artist, and each carries a one-tap "allow this".

Nothing leaves the device or iCloud. That avoids most of the legal exposure by construction, and Apple reviews Family Controls requests partly on whether an app collects usage data for profiling.

### Data model & types
```swift
/// Debounced: the term the kid settled on, not every keystroke.
struct SearchEvent: Identifiable {
    let id: UUID
    let kidID: UUID
    let term: String
    let at: Date
    let resultCount: Int
    let blockedCount: Int
    let gaveUpEarly: Bool       // we stopped looking; NOT "nothing matched"
}

struct PlayEvent: Identifiable {
    let id: UUID
    let kidID: UUID
    let songID: CatalogID
    let albumID: CatalogID?     // nil when lineage never resolved
    let artistID: CatalogID?    // nil likewise; such rows cannot group by artist
    let displayName: String     // captured at play time; survives delisting
    let at: Date

    /// Seconds actually HEARD — not the playhead position it used to be.
    /// The scrubber separated the two: a kid who listens for a minute and
    /// drags back to the start is at position 0:10 having heard 1:10. This is
    /// accumulated across seeks, so it may EXCEED the track's duration, and a
    /// report that treats it as a position will be wrong in both directions.
    let secondsPlayed: Int

    let origin: Origin
}

struct BlockEvent: Identifiable {
    let id: UUID
    let kidID: UUID
    let itemID: CatalogID
    let displayName: String
    let artistID: CatalogID?
    let at: Date
    let reason: Reason          // includes restrictedOutsideApp
    let origin: Origin
}

/// Derived from events, not the source of truth while those events exist.
struct WeeklySummary {
    let week: DateInterval
    let topArtists: [(name: String, seconds: Int)]
    let topSongs: [(name: String, plays: Int)]
    let firstTimeHeard: [String]
    let blocksByArtist: [(name: String, count: Int, sample: BlockEvent)]
    let totalListeningSeconds: Int
}
```

### Algorithm
**Search logging.** One row per term the kid settled on.

```text
onSearchTextChanged(text)

1. cancel any pending write; schedule one for now + 1.2s
2. on fire, if text is unchanged and non-empty, write the SearchEvent
3. if the kid taps a result first, write immediately, then log the play
```

**Play logging.** Written on stop, since duration is the signal.

```text
1. secondsPlayed < 5 -> discard; a mis-tap is not a listen
2. otherwise write the PlayEvent with its origin
```

**Accumulating **`secondsPlayed`**.** The player owns this, not the log — the log is handed a number. It stopped being the playhead position when the scrubber arrived, and is maintained without any polling because a seek is the only event that breaks the correspondence between position and listening:

```text
on play(newTrack)      heard := 0 ; stretchStart := 0
on seek(to: target)    heard += max(0, position - stretchStart)
                       stretchStart := target
on read                heard + max(0, position - stretchStart)
```

A kid who listens a minute, drags back to the start and listens ten more seconds reports 70, not 10. One who drags forward past two minutes reports only what they sat through. Replaying a chorus four times counts four times, which is why the value may exceed the track's duration.

**Block logging.**

```text
1. write every block, including results filtered out of a search that the kid
   never saw
2. record the reason, and the artist from ancestry when there is one
```

**Weekly summary.** Derived on read.

```text
1. take the week's plays and blocks for that kid
2. topArtists  := plays grouped by artist, summing seconds
3. topSongs    := plays grouped by song, counting
4. firstTimeHeard := songs with no play before the week started
5. blocksByArtist := blocks grouped by artist, keeping one sample each
6. total := sum of secondsPlayed
```

Summing stays correct under the change: each row is real listening time, so the total is real listening time even where one row exceeds its own track's length.

**Retention sweep.** On launch.

```text
1. for each week entirely past the cutoff:
     compute and persist its summary, then delete that week's raw events
2. leave a week straddling the cutoff whole, or the summary would be computed
   from a half-deleted week
```

### Invariants & limits
- Logging runs in all three modes.
- Every block is logged, including ones filtered out of search results the kid never saw.
- A block carries the reason that produced it.
- Search terms are debounced to one row per settled term.
- A play under five seconds is not recorded.
- Play and block rows capture the display name at the time.
- Weekly summaries are derived on read while their events exist.
- Raw events are deleted after the retention window; their summary is kept.
- No event or field is sent to a server we run or to any third party.
- No third-party analytics SDK is present in the app.
- Delete-everything removes summaries as well as raw events.
- Logging never blocks or delays playback.
- The kid is told they are being logged.

### Failure & concurrency semantics
**A dropped log line is acceptable; a stalled player is not.** Writes are fire-and-forget off the playback path. A failed write loses the event. No safety decision reads from the log.

**Missing lineage.** A row logged before ancestry resolved has no artist, so it counts toward totals but cannot be grouped. The report shows it under its own name rather than dropping it.

**A block with no visible cause.** Playback refused by Screen Time or Apple Music's controls is recorded as an outside restriction, not one of our reasons. Otherwise a parent reads their own rules as having blocked something they did not.

**Retention racing a read.** The sweep runs on launch, before any report renders.

**Clock changes.** Timestamps use device time, which a kid can change. Weekly bucketing is approximate and a report is not forensic.

**Concurrency.** One writer, the kid's session on this device. Once sync exists, a parent's report may lag; the screen should show when it was last updated.

### Data dependencies
**Verdicts and reasons** — from the policy engine at the moment of judgement. Captured then, because the policy that produced a reason may have changed by the time anyone reads the report.

**Display names and ancestry** — from the item being judged, copied into the event rather than referenced.

**Search outcome counts** — from `FilteredResults`. `gaveUpEarly` matters here: a search logged with zero results and `gaveUpEarly` true did not find nothing, it stopped looking.

**Device clock** — for timestamps, and not trustworthy.

**The kid identity** — local, known before any event can be written.

Nothing here needs the network, which is why logging keeps working when the rest of the app cannot.

### Migration & existing data
**Nothing to migrate.** No events exist.

**Fields absent at v1 are absent forever for that period.** `origin`, `gaveUpEarly` and `secondsPlayed` each cost a column now. Added later, every historical row lacks them. Record them from the start even if nothing displays them yet.

**The retention window is a decision, not a default.** Two positions are in tension in this project: a ninety-day detail window rolling up into summaries, versus keeping everything until a parent deletes it. They cannot both hold, and the choice is legal as much as technical. Shortening a window later means deleting data a parent relied on.

**Delete has to mean delete.** A summary surviving the events it came from is a record the parent asked us to destroy.

If sync arrives later, local events have to be adopted without duplicating, and the privacy analysis changes the moment events leave the device.

### Staged plan
**Stage 1 — record everything, show almost nothing.**

- Ships: all three event types written locally with every field, and a reverse-chronological list in the admin.
- Does not: summaries, grouping, approve-from-report, retention.
- Exit test: a kid session produces plays, searches and blocks with correct reasons, matching what actually happened.

**Stage 2 — the weekly summary.**

- Ships: top artists and songs, first-time-heard, blocks grouped by artist, total listening time.
- Does not: notifications, cross-week trends, comparisons between kids.
- Exit test: a parent reads one week and can say what their kid was into without opening the raw log.

**Stage 3 — the feedback loop.**

- Ships: one-tap "allow this" on a blocked group, with the option to widen to the artist.
- Does not: suggest anything automatically.
- Exit test: a level 1 list grows from the kid's own blocked searches over a fortnight of real use.

**Stage 4 — retention and deletion.**

- Ships: the chosen window enforced on launch, roll-up to summaries, delete-everything covering both.
- Does not: ship before the retention question is answered in writing.
- Exit test: events past the window are gone, summaries survive, delete-everything leaves nothing — verified by inspecting the store, not the UI.

## Review
_Not reviewed._

## Open notes
_None._
