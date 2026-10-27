# Parent Review

**Status:** restating

## Sections
### Motivation
We need to present usage data to the parent so they can make choices about allow / deny lists.

### Overview
The Parent Review section is a screen accessible only to admins that shows the child's activity: what they played, what they searched for, what was blocked and why, etc.

It is raw data display, not filtered by the policy engine.

It is not a raw data table but organized by the question the adult wants to answer.

### Volume is the design constraint
Every block is kept, including results the kid never saw. That rule is right and it is what makes the report valuable — and it has an arithmetic consequence nobody has had to face yet, because nothing has ever read the table.

`FilteredCatalog` over-fetches to survive filtering: a multiplier of 3 against a page cap of 25 (Apple Music rejects a larger `limit` outright). Every discarded result is a block row. So a level 2 kid typing one term that brushes explicit material can log tens of block rows from a single search, none of which they saw, and the search itself contributes exactly one row.

Over a week of ordinary use the block table will outnumber the play table by an order of magnitude, and the great majority of it will describe our filter rather than the child.

The reverse-chronological list of everything, which is what `Activity Log and Reports` stage 1 proposes as the first thing a parent sees, is therefore mostly noise — and worse than noise, because a parent scrolling a wall of blocked song titles draws precisely the wrong conclusion about what their kid has been doing.

**The default view is grouped, and the raw stream is a deliberate second step.** Not hidden — a parent who wants the whole record can have it, and the promise of this app is that it exists. But it is not the front door.

**Counts are always split by reach, never summed.** "41 blocks" is a number about our filter. "They reached for 2; we filtered 39 they never saw" is two facts, and only the first is about the child (see The column that is missing).

**Groups are sorted by what the kid reached for**, not by volume. Otherwise the loudest group is whichever artist happens to have the most explicit tracks in the catalog, which is a fact about that artist's discography and nothing to do with this family.

### The columns that are missing
Two, found one after the other. The first from reading the call sites, the second from trying to build the thing this spec is named for.

### `reach` — which blocks the kid actually saw

Both block paths in `Session` call the same private writer:

- `logSearch` and `logBlocked` write a row for every result the engine filtered out of a page — the kid never saw these.
- `play`, `toggleFavorite` and `addToPlaylist` write a row when the kid acted on something and was refused — the kid reached for these.

The two produce rows that are **identical in storage**. Both carry `origin: .search(term:)` when the block happened during a search, both carry a reason, both carry the same columns. Nothing written down distinguishes them.

For a parent that difference is not a detail, it is the whole meaning of the row:

> _Your child tried to play a song called ——._
>
> _A song called —— appeared in a page of results we filtered before they saw it._

The first is a fact about their child. The second is a fact about our filter, and it is dozens of times more common (see Volume is the design constraint). A screen that cannot tell them apart either invents intent the kid never had, or buries the handful of rows that describe real intent under everything else.

```swift
public enum BlockReach: String { case unseen, reached }
```

It is the same argument the four origin columns were added under — a column absent at v1 is absent for that period forever — arriving one release later only because this is the release that reads them. It costs one column and five call-site classifications.

`reach` is also the only field on a block row that describes the **child**. Everything else on `BlockEventRecord` is about the item or about the rule.

### `rating` — the input every annotation turns on

This one is not a refinement. Without it the feature does not work.

No event row stores a content rating. Re-judging a stored play therefore hands the engine an `Item` with `rating: nil` — and for a `denyPlusAuto` kid with the default `UnratedBehavior.block`, that comes back `.blocked(.unrated)`. Every row. A parent opening the report would read that their child can no longer play a single thing they listened to all week, and every word of it would be an artifact of our own records rather than a fact about the music.

The alternative to a column is resolving each row through the catalog at read time, which needs the network and breaks the property this whole screen rests on: that a report renders offline from strings copied at write time.

So the rating is written down as well — and writing it down turns a three-state problem into a four-state one:

```swift
public enum StoredRating {
    case clean
    case explicit
    case unrated    // the catalog answered and carried no rating: a FACT
    case unknown    // nobody wrote one down: NOT a fact about the item
}
```

Collapsing the last two would reintroduce the same bug in miniature. Under `UnratedBehavior.block` a genuinely unrated item is blocked today and will be tomorrow, which is worth telling a parent; an item nobody recorded a rating for is simply a row we cannot judge. That distinction is what `AncestryConfidence.unknown` reads (see Data model & types), and it is why the annotator has a `ratingIsRecorded` flag rather than inspecting `rating == nil`.

The column pays a second dividend. Open research question 1 asks how often `contentRating` is `nil`, answered so far only by a hand-run probe on a US storefront. With this column the log answers it continuously, from real use, across whatever catalogue a real child actually reaches.

### Why both are free, and only now

Two cases in `BlockReach` and not three, and a non-optional `rating` column with no backfill, **only because nothing has shipped.** With rows already on a device each would need an extra case for the period before it existed — the same reasoning that makes `PlaybackOrigin(stored:)` return `nil` rather than claiming everything came from the home screen. That option closes the day a build reaches a real device (see Migration & existing data).

### What a parent reads first
The shape of the screen, stated once so the stages have something to converge on.

**One kid at a time, chosen here.** The review section has its own kid picker and does not touch the active kid — switching the active kid is a thing that changes what a child sees on their device, and reading a report must never do it. A parent reviewing one child while another is mid-song is the normal case on a shared device.

**A week, then four questions.** In a parent's words rather than ours:

- **What they listened to** — top artists and songs by time, the individual plays behind them, with origins: _from their playlist Spooky_, _while searching for monster_.
- **What they went looking for** — search terms verbatim, in order, with what came back. A term with zero results and `gaveUpEarly` reads as _we stopped looking_, never as _nothing matched_; that distinction exists in the schema precisely so this line can be honest.
- **What they could not reach** — blocks, grouped by artist, split by reach, each group offering allow or deny at the item or the artist.
- **What they kept** — favorites and playlists, unfiltered, with the ones the kid cannot currently play marked and explained, and the ones that arrived with the account distinguished from the ones they chose.

**Then: the whole record.** Reverse-chronological, paged, everything, including the rows the grouped view compressed. It exists because the promise of this app is that the parent can see everything, and because a grouped view is an interpretation — a parent should be able to check ours.

**And: delete.** Per kid, on this screen, because the screen that shows a parent what we hold is the honest place to offer removing it.

**One line of copy that is not decoration.** The screen states, once, that times come from the device clock and can be wrong, and that this is a record rather than evidence. A parent about to have a conversation with their child on the strength of a timestamp should have read that first.

### Data model & types
Almost all of this is a **read model**. The store already holds most of what the screen shows; these types are how it crosses an actor boundary and arrives annotated. Two fields are new storage, and both are argued for separately (see The columns that are missing).

```swift
// ---------------------------------------------------------------------
// The two new stored columns.
// ---------------------------------------------------------------------

/// Whether the kid ever saw the thing that was blocked. On BlockEventRecord.
///
/// Two cases, not three: nothing has shipped, so there are no rows that
/// predate the column. Had there been, the honest choice would be a third
/// case rather than defaulting to either of these — the same reasoning that
/// makes `PlaybackOrigin(stored:)` return nil instead of falling back to
/// `.home`.
public enum BlockReach: String {
    case unseen    // filtered out of a batch before display; the kid did nothing
    case reached   // pressed play, tapped the heart, added to a playlist
}

/// A rating as an event row keeps it. On BOTH PlayEventRecord and
/// BlockEventRecord.
///
/// `ContentRating?` is already three-state; writing it down makes it four,
/// and the fourth case is the one that matters. Without this column every
/// re-judged play of a `denyPlusAuto` kid comes back blocked-as-unrated.
public enum StoredRating {
    case clean
    case explicit
    case unrated    // the catalog answered and had no rating — a FACT
    case unknown    // nobody wrote one down — NOT a fact about the item

    var rating: ContentRating?   // nil for both empty cases
    var isRecorded: Bool         // false only for .unknown
}

// ---------------------------------------------------------------------
// The read model.
// ---------------------------------------------------------------------

/// Everything the store knows about one kid over one interval, unfiltered.
///
/// Values, not `@Model` objects: built inside `ReviewReader`'s own context
/// and handed out as `Sendable` structs, the same contract `EventLog` has
/// in the other direction.
public struct ReviewWindow: Sendable {
    public let kidID: UUID

    /// Half-open, in device time. Never open-ended: an unbounded window is
    /// a fetch with no limit over the largest table in the store.
    public let interval: DateInterval

    public let plays: [PlayEvent]
    public let searches: [SearchEvent]
    public let blocks: [ReviewedBlock]

    /// Rows whose stored columns did not read back into a typed event.
    /// A count rather than the rows, because there is nothing to show —
    /// but a silent zero and a silent forty look identical, and one of
    /// them is a bug in us.
    public let unreadable: Int

    /// When this window was built. The kid may be playing right now, and
    /// the song playing has no row yet — a play is written on stop.
    public let builtAt: Date

    public let coverage: Coverage
}

/// What a window can and cannot answer, because retention ate part of it.
///
/// Exists from the first release even though the sweep does not, because
/// an empty list means "nothing happened" and a swept week must not be
/// able to say that.
public enum Coverage: Sendable, Hashable {
    /// Raw events cover the whole interval.
    case complete

    /// Raw events exist only at or after this date; before it there are
    /// summaries and nothing else.
    case summarisedBefore(Date)
}

/// A stored fact plus today's verdict on it.
///
/// The two disagree constantly and the disagreement is the most useful
/// thing on the screen: *they played this forty times and you denied the
/// artist on Tuesday.* The fact is history; `now` is a fresh question
/// asked of today's policy.
public struct Annotated<Fact: Sendable>: Sendable {
    public let fact: Fact

    /// What the engine says **now**. `nil` when it could not honestly be
    /// asked — see `AncestryConfidence.unknown`.
    public let now: Verdict?

    public let confidence: AncestryConfidence

    /// nil, true or false. A screen must render three states, never two.
    public var isAllowedNow: Bool? { now?.isAllowed }
}

/// How much the annotator actually knew.
///
/// Named for ancestry because that was the only gap the first draft of
/// this spec knew about. The rating turned out to be the other one, and
/// the more important.
public enum AncestryConfidence: Sendable, Hashable {
    /// Everything the engine consulted was on the row. Exact.
    case exact

    /// Something the engine consulted was missing, but not the thing that
    /// decided. Provisional in the established sense: a deny may fail
    /// open, allow-only fails closed. Shown as "probably", never as fact.
    case itemOnly

    /// The missing input is the one that would decide. No verdict is
    /// offered at all, because the only one available would be an artifact
    /// of our own ignorance rather than a statement about the item.
    case unknown
}

/// What a row knows about its item, and what it only appears to.
///
/// Two flags rather than inspecting the `Item`, because both absences are
/// invisible from the value: an empty `ancestors` looks the same whether
/// the item has no containers or nobody resolved them, and a `nil` rating
/// looks the same whether the catalog said so or nobody asked.
public struct Knowledge: Sendable {
    public var item: Item
    public var ancestryIsComplete: Bool
    public var ratingIsRecorded: Bool
}

/// A block, with the entry that produced it resolved to something a
/// parent recognises.
public struct ReviewedBlock: Sendable {
    public let event: BlockEvent

    /// For `deniedByParent`: the entry named by `deniedByKind`/`deniedByID`
    /// as it stands **today**. `nil` when that entry has since been
    /// removed — the block still happened, the rule no longer exists.
    /// Never re-derived from whatever rule *would* catch it now.
    public let deniedBy: PolicyEntrySnapshot?
}

public struct PolicyEntrySnapshot: Sendable, Hashable {
    public let id: CatalogID
    public let displayName: String
    public let kind: PolicyEntry.Kind
}

/// Blocks collapsed to the unit a parent actually reads.
///
/// Grouping is by artist because that is the question ("is my kid into
/// this band?") and because it is the unit approve-from-report widens to.
public struct BlockGroup: Sendable, Identifiable {
    /// `nil` when no row in the group resolved an artist. Such groups are
    /// keyed by `displayName` instead and cannot be widened to an artist.
    public let artistID: CatalogID?
    public let displayName: String

    /// Split, never summed into one number. See Volume is the design
    /// constraint: `unseen` is usually two orders of magnitude larger and
    /// says nothing about the child.
    public let reached: Int
    public let unseen: Int

    /// More than one when different rules caught different tracks.
    public let reasons: Set<BlockReason>

    public let firstAt: Date
    public let latestAt: Date

    /// A row the kid **reached for** when the group has one, otherwise the
    /// most recent. It carries the origin, which is what turns a group
    /// into a sentence: "while searching for monster".
    public let sample: BlockEvent
}

/// The kid's shelf as the admin sees it: never filtered, always annotated.
///
/// The parallel of `MergedLibrary.favorites()`, which filters. Both read
/// the same providers through the same seam; only this one keeps the
/// blocked half.
public struct ReviewedLibrary: Sendable {
    public let favorites: [Annotated<FavoriteRow>]
    public let playlists: [ReviewedPlaylist]

    /// One entry per provider this device has CONFIGURED, live or not.
    /// Providers that do not exist yet are absent rather than reported as
    /// broken — listing the unbuilt Apple provider as failed would be
    /// describing our roadmap as a fault on this device.
    public let providers: [LibraryProviderID: ProviderHealth]

    /// Stored rows the catalog would not resolve on this read. NOT the
    /// ISRC/UPC drop rate of open research question 2 — that belongs to
    /// the Apple provider's pass, which does not exist yet.
    public let unresolved: Int

    /// False when the catalog did not answer at all. Said once, not per
    /// row.
    public let isResolved: Bool
}

public struct ReviewedPlaylist: Sendable {
    public let row: PlaylistRow
    public let entries: [Annotated<PlaylistEntryRow>]

    /// Our copy accepts edits that Apple's silently will not. Permanent
    /// rather than transient, so the admin states it plainly.
    public var divergesFromApple: Bool
}

public enum ProviderHealth: Sendable, Hashable {
    case live

    /// Deliberately absent. Not a fault — an answer the parent gave, or a
    /// question nobody has put yet.
    case notConfigured(Reason)

    /// Threw on this read. Admin-facing; nothing about provider
    /// availability is ever shown to a kid.
    case failed(String)

    public enum Reason { case sharedDevice, notYetAsked }
}

/// Rendered from `origin` columns, in a parent's words rather than ours.
///
/// `nil` from the stored columns is `.unknown` here rather than a guess.
public enum OriginDescription: Sendable, Hashable {
    case home
    case search(term: String)
    case browse(CatalogID, name: String?)     // name nil => not resolvable offline
    case catalogPlaylist(CatalogID, name: String?)
    case kidPlaylist(UUID, name: String?)     // name nil => playlist since deleted
    case unknown
}
```

### Algorithm
**Building a window.** Three bounded fetches inside `ReviewReader`'s own context.

```text
window(kid, interval)

1. assert interval is bounded          // never open-ended; see Data model & types
2. rows := fetch each of the three event tables where
              kid == kid AND at in interval, sorted by `at` descending,
              each with its own fetchLimit
3. typed := [] ; unreadable := 0
   for each row:
     e := row.event                    // nil when origin/reason/reach columns rot
     if e == nil: unreadable += 1 ; continue
     typed += e
4. for each block whose reason is deniedByParent(id):
     deniedBy := today's entry for (id.kind, id), or nil once removed
5. coverage := (no summary overlaps interval) ? complete
                                              : summarisedBefore(end of that week)
6. return ReviewWindow(..., builtAt: now)
```

No policy is consulted here. Step 3 discards nothing but unreadable rows — in particular it does **not** drop blocked items, which is the whole difference between this reader and every other one in the app.

The three fetches are written out rather than made generic over the tables. `#Predicate` resolves its key paths against a concrete model type; written once over a protocol it compiles and then fails at run time, which is the worst of the three outcomes.

**Annotating.** Pure, synchronous, offline.

```text
annotate(fact, knowledge, engine)

1. verdict := engine.evaluate(knowledge.item)
2. confidence := howFarToTrust(verdict, knowledge, engine.policy)
3. return Annotated(fact,
                    now: confidence is unknown ? nil : verdict,
                    confidence)
```

```text
howFarToTrust(verdict, k, policy)

1. verdict is blocked-by-a-deny -> exact
     // a rule already fired and nothing unresolved could unmake it
2. mode reportOnly -> exact          // only a deny can decide, and none did
3. mode allowOnly:
     allowed -> exact                // a listed allow matched; definitive
     blocked -> k.ancestryIsComplete ? exact : itemOnly
                                     // an unresolved container might be listed
4. mode denyPlusAuto:
     a. rating cannot decide (artist or playlist), or the item is itself on
        the allow list -> skip to (d)
     b. NOT k.ratingIsRecorded -> unknown
          // the deciding input is missing; any verdict here would be a
          // statement about our records rather than about the item
     c. unratedBehavior is inheritFromAncestor AND item.rating is nil AND
        NOT k.ancestryIsComplete -> unknown
          // it reaches for ancestor ratings, which no row stores
     d. allowed -> k.ancestryIsComplete ? exact : itemOnly
        blocked -> exact             // more lineage could only add reasons
```

Every asymmetry above runs the same way: **more information can only ever add a deny, never remove one.** That is why a block is usually exact and an allow is usually the provisional one — the exact opposite of the kid-facing paths, where the provisional case is the one that has to fail closed.

A `PlayEvent` supplies both flags from its own columns: `albumID` and `artistID` for lineage, `rating` for the rating. A `FavoriteRow` supplies neither — the library stores an identifier and a name, and there is no rating column on it — so an unresolved favorite annotates as `unknown` rather than as a confident block.

**Grouping blocks.** The default view.

```text
groupBlocks(blocks)

1. key(b) := b.artistID, or its displayName when lineage never resolved
2. for each key:
     reached := count where reach is reached
     unseen  := count where reach is unseen
     reasons := set of reasons
     name    := the artist row's own name if the artist itself was blocked,
                else the newest track's
     sample  := newest row with reach reached, else the newest row
3. sort by (reached descending, then latestAt descending)
4. never sum reached and unseen into one count
```

Step 3 puts what the kid went for above what we filtered on their behalf. Sorting by volume instead would top the list with whichever artist happens to have the most explicit tracks in the catalog, which is a fact about that discography and nothing to do with this family.

**Reading the library unfiltered.**

```text
reviewedLibrary(kid)

1. for each configured provider p:
     health[p] := live / notConfigured(sharedDevice | notYetAsked)
2. rows := union over readable providers, deduplicated by catalogID;
     a provider that throws sets health[p] := failed and contributes nothing
3. resolve every favorite AND every playlist entry in ONE batch, with
     ancestry, best-effort
4. annotate each row: resolved -> full knowledge; unresolved -> neither flag
     // NOT filtered. The kid's read filters here; this one does not.
5. unresolved := rows the catalog did not answer for
```

**Describing an origin.** Offline first.

```text
describe(origin)

1. home                  -> home
2. search(term)          -> search(term)          // verbatim, as typed
3. browse(id)            -> browse(id, cachedName(id))
4. playlist(id)          -> catalogPlaylist(id, cachedName(id))
5. kidPlaylist(uuid)     -> kidPlaylist(uuid, playlistName(uuid))
                            // nil once the kid has deleted it
6. columns unreadable    -> unknown
```

Names come from what is already stored or cached. The screen never blocks on a catalog fetch to render a row — an unresolved name renders as the identifier's kind ("an album") rather than as a spinner, and a second best-effort pass improves it if it can.

**Approve from report.**

```text
approve(group, scope)

1. scope item   -> addEntry(allow, group.sample.itemID, name)
   scope artist -> require group.artistID, then addEntry(allow, artistID, name)
2. the write is awaited and its failure surfaced, exactly as the list editor's
3. deny works the same way
4. the report is NOT rewritten: past blocks keep the reason that produced
   them. Only the annotation changes on the next read.
```

Step 4 is the asymmetry worth stating: allowing something does not erase the history of it having been blocked. The event records what happened; the annotation records what would happen today.

**Deleting a kid's data.** On the admin's own context, not the reader's.

```text
delete(kid, scope)

1. scope history    -> every search, play and block row for that kid,
                       AND every WeeklySummaryRecord for that kid
2. scope everything -> the above, plus favorites, playlists and playlist
                       entries. Lists, mode and unrated behavior stay.
3. the confirmation names what goes, including that playlists are the kid's
   own work and cannot be recovered
4. awaited, with failure surfaced
5. rebuild the window from scratch afterwards rather than patching it
```

A summary surviving the events it came from is a record the parent asked us to destroy, which is why step 1 takes both tables.

It runs on the context that owns the kid records rather than on `ReviewReader`'s, and that is not a stylistic choice. The admin already holds those objects with their favorites and playlists materialised; a delete run from a second context would leave that copy holding rows the store no longer has, and the next screen a parent opened would show them their child's deleted playlists.

### Invariants & limits
- **Nothing on this screen is filtered by policy.** Every row the store holds for the kid is shown, including ones the kid cannot see and never saw.
- **Every read on this screen goes through **`ReviewReader`** or **`MergedLibrary.reviewed()`**.** No review surface calls `FilteredCatalog`, `MergedLibrary.favorites()`, or any other filtering path.
- **Neither seam has an API that removes a row.** They take a policy only as an annotator.
- **The review section is reachable only through the admin gate**, by every route, exactly as the rest of the admin is.
- **A parent may review any kid, not only the active one.** Reviewing does not switch the active kid or disturb a session in progress.
- **Reading a report writes no event.** No search, play or block row is ever produced by the admin.
- **Every row renders from stored strings.** `displayName` was copied at write time and is what the screen shows; no network call is required to draw any row.
- **Artwork is a URL and is allowed to fail.** A row with no image is a row, not an error.
- **Search terms are shown verbatim, as the kid typed them**, never normalised, corrected, deduplicated or censored.
- **A block the kid reached for and a block they never saw are never presented as the same number.** Counts are always split (see The columns that are missing).
- **A stored verdict and today's verdict are distinct and both are shown.** The event's `reason` is what happened; the annotation is what would happen now.
- **A verdict is offered only when the input that would decide it was recorded.** Where it was not, the screen shows a third state and never a block.
- **An annotation computed without full lineage is labelled as provisional** and never stated as a fact.
- **More information can only add a deny, never remove one.** Every confidence rule follows from this, which is why a block is usually exact and an allow is usually the provisional one.
- **The window is always bounded in time** and every fetch carries a limit.
- **A window states when it was built.** No screen implies it is live while a kid is playing.
- **An empty interval and a swept interval are never drawn the same way.** `Coverage` distinguishes them.
- **Rows that do not read back are counted and the count is shown.** A silent zero and a silent forty must not look identical.
- **Approve-from-report writes through the same path as the list editor**, awaited, with failures surfaced.
- **Approving or denying never rewrites history.** Past events keep the reason that produced them.
- **Widening to an artist is offered only when the group resolved one.**
- **Nothing in the report is a permission.** A favorite, a play, or a block confers nothing on its own.
- **The admin never edits the kid's library.** It reads every favorite and playlist and removes none; a parent who wants something gone denies it.
- **Delete removes summaries along with raw events**, and delete-everything additionally removes favorites and playlists. Both run on the context that owns those records.
- **Nothing on this screen leaves the device.** No share sheet, no export, no third-party analytics (see Export is deliberately absent).
- **Provider health is admin-facing only** and never surfaces on any kid screen.
- **Timestamps are device time and the screen says so once**, not per row. A report is not forensic.

### Failure & concurrency semantics
**This screen fails toward showing too much.** Everywhere else in the app the safe direction is to hide: a provisional verdict on empty ancestry denies under allow-only, a shelf drops what it cannot judge. Here the safe direction is the opposite. A parent shown a row they did not need to see has lost nothing; a parent shown a shelf with the interesting half quietly missing has been told something false about their child.

With one exception, which is the other half of the same principle: **it does not overstate.** A verdict is offered only where the input that decides it was recorded. Showing our own gaps as blocks would be the same lie in the other direction — a wall of "they can't play this any more" that is really "we did not ask".

**The kid is playing while the parent reads.** Guaranteed on a shared device and normal on any device. The window is a snapshot taken at `builtAt`, and the current track is not in it — a play is written on stop, so the song playing right now has no row yet. The screen states its "as of" time rather than pretending to be live. Refresh is a pull, not a subscription: a report that reorders itself under a reading parent's thumb is worse than one that is a minute old.

**A verdict that has changed since the event.** Expected, not a fault, and the reason the annotation exists. A play row for a song the parent denied yesterday shows both: they listened to it on Tuesday, and they cannot now.

**Missing lineage on an event row.** `albumID` or `artistID` is `nil` because ancestry never resolved at write time. The row still counts toward totals and still appears, grouped under its own name rather than dropped — the same treatment `Activity Log and Reports` already specifies. Its annotation is `itemOnly` where lineage is what was in doubt.

A _song_ block is never fully resolved whatever came back, because `BlockEventRecord` stores the artist and not the album. A deny on the album is therefore invisible to a re-judged block row, and the confidence says so rather than the verdict pretending otherwise.

**No rating on a library row.** Favorites and playlist entries store an identifier and a name, never a rating and never lineage. When the catalog resolves them the verdict is exact; when it does not — offline, or the item delisted — there is nothing to judge the level 2 rating check with, and the annotation is `unknown` with no verdict at all. Deny still bites in that state, because a deny needs no rating.

This is the one case where the offline story is genuinely poorer than the online one, and the honest resolution is silence rather than a confident wrong answer.

**Stored columns that do not read back.** `PlaybackOrigin(stored:)` and `BlockReason(stored:)` both return `nil` rather than falling back, and `BlockReach` joins them. Those rows are counted into `unreadable` and shown as a count. They are the first evidence anyone will ever have that these columns round-trip, and a screen that swallowed them would destroy that evidence.

`StoredRating` is the deliberate exception: an unreadable string becomes `unknown` rather than discarding the row, because `unknown` already _is_ the "we do not know" case and there is nothing a `nil` would add beyond throwing away an otherwise perfectly readable row over an advisory field.

**A **`deniedByID`** naming an entry that no longer exists.** Common after any approve-from-report. The block keeps its stored reason — it was denied by a parent, that is what happened — and `deniedBy` is `nil`, rendered as "a rule you have since removed". Never re-derived: guessing which current entry _would_ have caught it invents a fact. Lookup is by identifier **and kind together**, because MusicKit identifiers are unique only within a type and an album must not answer for a song.

**An origin pointing at a deleted kid playlist.** `PlaybackOrigin.kidPlaylist` carries a local UUID and a kid may delete the playlist. The name is gone and is not recoverable, so the row reads "from a playlist they have since deleted". This is the one origin whose target can vanish entirely, because it is the one identifier in the store that is not an Apple Music one.

**A library provider that throws.** The union read keeps whatever the other providers returned — `MergedLibrary` already swallows a provider failure so one dead provider does not empty a shelf. On this screen swallowing is not enough: `ProviderHealth.failed` is shown, because a short shelf and a broken read look identical and only one of them is about the child. The kid's side is unchanged and still says nothing.

**Offline.** The whole screen renders: every string it needs was copied at write time. Artwork is absent, catalog names for browse origins are absent, and library rows lose their rating-derived verdicts as above. Event rows do not, because they carry their own rating — which is the entire payoff of that column.

**A retention gap.** Once the sweep ships, an interval before the cutoff has summaries and no raw rows. `Coverage.summarisedBefore` makes the screen say so. Without it an old week reads as a week the kid did nothing, which is a lie the parent has no way to detect.

**Clock changes.** Device time, which a kid can change, and a kid who wants a quiet hour off the report can change it. Bucketing is approximate, ordering can be locally wrong, and the screen says once that this is a record rather than evidence.

**Concurrency, within one device.** Three contexts: the admin's, which writes policy and performs deletes; `EventLog`'s, which the kid's session writes events on; and `ReviewReader`'s, which only reads. A row written mid-read appears in the next window and no read ever blocks a write, which preserves the rule that logging never delays playback.

**Concurrency, once sync exists.** A parent's device may hold a stale copy of a kid's activity, and two parents may read different reports of the same afternoon. The "as of" line is already the mechanism for saying so and should name the source once sync arrives. Nothing here resolves conflicts; nothing here needs to, because the review section never writes an event.

**A delete racing a read.** Delete is awaited and the window is rebuilt from scratch afterwards rather than patched. A partially-deleted report on screen would be indistinguishable from a report of a quiet week. It runs on the admin's context rather than the reader's for the reason given in Algorithm.

### Data dependencies
Everything this screen needs to draw a row is already on disk. That is the property to protect: the report is the one admin surface that must work with no network, no subscription and no MusicKit authorization, because a parent may be reading it on a plane and because it is the surface a parent uses to decide whether to keep the app.

**The three event tables** — local SwiftData, in the named custom CloudKit zone. Reached through `ReviewReader`, a `@ModelActor` with its own context, distinct from both the main context the admin writes policy and deletes on and the `EventLog` context the kid's session writes events on. Before the first fetch returns there is a spinner over an empty window; there is no "probably empty" state, because an empty report and an unloaded report are different claims.

**Display names and artwork URLs** — columns on the event rows, copied at write time and never refreshed. This is why a delisted song still reads as a name and why nothing here waits on the catalog. Artwork is a URL that may 404; the row draws without it.

**Ancestry for annotation** — `albumID` and `artistID`, columns on `PlayEventRecord`; `artistID` alone on `BlockEventRecord`. Present or `nil`, never fetched. Their absence downgrades an annotation rather than delaying it.

**The rating for annotation** — a column on both event tables, written at the moment of judgement. The one input the engine consults that is not otherwise recoverable offline, and the reason a re-judged week is a fact rather than an artifact (see The columns that are missing). Absent on library rows, which is why those degrade differently.

**The kid's policy** — `mode`, `unratedBehavior` and the entries, all on the kid record, local and synchronous. Built into an engine the same way every other surface builds one, through `makeEngine()`. If it were built any other way the annotation could disagree with what the kid's device actually does, and a report that disagrees with the app is worse than no report.

**Policy entries, for **`deniedBy` — local, read by identifier and kind together, because a MusicKit identifier is unique only within its type. Resolved at read time and allowed to come back empty (see Failure & concurrency semantics).

**The kid's library** — through `MergedLibrary`'s providers, which is the seam and the only door, built for whichever kid is being reviewed rather than for the active one. The CloudKit provider is always live and synchronous. The Apple Music provider needs authorization, a subscription and `isSharedDevice == false`; when it is not live the screen says which, rather than showing a shelf that is quietly half a shelf. This is the only dependency on this screen that can touch the network, and also the only one whose absence is stated rather than hidden.

**Weekly summaries** — local, and empty until the retention sweep ships. Read to compute `Coverage`, which means the screen depends on them from the first release even though nothing writes one yet.

**Kid playlist names, for **`kidPlaylist`** origins** — local, by UUID, and may be absent because the kid deleted the playlist. There is no fallback and none is invented.

**Catalog names for artists and browse origins** — the one genuinely optional input, and the only reason a second pass exists at all. A block row keeps an artist _identifier_ and its own title, so without this a group of one artist's tracks is labelled with whichever song was blocked most recently: technically true and useless to read. Fetched best-effort after the screen has already drawn, never awaited before it.

**The device clock** — for bucketing and for "as of". Not trustworthy, stated once on the screen.

**Which kid** — chosen on this screen, independent of the active kid, and known before any fetch.

### Migration & existing data
**Nothing has shipped, so nothing needs migrating** — and that is exactly why two schema changes belong in this spec rather than in a later one.

`reach`** and **`rating`** are free right now and never will be again.** `reach` is a non-optional column on `BlockEventRecord`; `rating` is a non-optional column on both `BlockEventRecord` and `PlayEventRecord`. Neither has a legacy row to interpret. The day something ships, adding either means every historical row carries a value that cannot be recovered, which forces an extra enum case and a screen that has to explain it. Add both before the first release that logs anything in anger (see The columns that are missing).

The second is not a nicety. Without a stored rating the annotation this whole screen is built on cannot be computed at all: every re-judged play of a level 2 kid comes back blocked-as-unrated, and the report tells a parent their child can no longer play anything they listened to.

**This release is the audit of the columns nobody has read.** `origin`, `originTerm`, `originKind`, `originID`, `gaveUpEarly`, `deniedByKind`, `deniedByID`, `itemKind`, and `LibraryOrigin` were all added on the argument that a report would want them. This is the report. Any of them that turns out to be wrong — wrong shape, wrong granularity, unpopulated in practice — is discovered here, while it is still free to change. Treat a surprise in this stage as the point of the stage rather than as a defect. It has already produced two.

**Three things to get right in this first version.**

**The two seams own every read from the start.** If the first screen reads the store directly "just for the raw list", the unfiltered rule becomes a convention instead of a seam, and the second screen — written later, by someone reaching for the read API that was already there — is the one that quietly filters.

**Coverage from the first release, before the sweep exists.** It costs one enum and a summaries query now. Added after retention ships, every already-swept week reads as a week the kid did nothing, and there is no way to tell afterwards which weeks those were.

**Delete covers summaries from the first release.** The table exists, nothing writes it, and delete must still take it — otherwise the release that starts writing summaries is the release that starts leaving orphans behind a delete a parent already trusted.

**The retention window is still an open decision and this screen is now a stakeholder in it.** `Activity Log and Reports` records the tension — ninety days rolling into summaries versus keeping everything until a parent deletes it — and this spec adds a consideration: the review section is what makes the window visible. A parent who reads a year of history in month one and finds it gone in month four experiences a deletion, not a policy. Whichever window is chosen must be stated on this screen before it takes effect, not discovered through absence.

**Favorites and playlists are exempt from retention and must stay exempt.** They are the records holding the most of a child's own work. A sweep written against "child data older than N days" would take them; the delete on this screen is the only thing that should, and it says so out loud, by name, in its own confirmation.

**What sync will have to adopt.** Events written on one device, read on another, with no conflict to resolve because this screen never writes one. The one thing sync changes here is honesty about freshness: "as of" has to name a device or a sync time rather than a local clock. That is a copy change over a field that already exists, which is why it is cheap to leave for later.

### Staged plan
Stages 0 to 5 are **built**. Stage 6 is deliberately not, and says why.

**Stage 0 — the columns, before anything reads.** _Done._

- Ships: `BlockReach` and `StoredRating` on the events and their records, with every block call site in `Session` classified — `.unseen` from `logSearch` and `logBlocked`, `.reached` from `play`, `toggleFavorite` and `addToPlaylist` — and every play and block carrying the catalog's rating. `reach` has no default parameter, so no call site can forget which of the two it is.
- Does not: display anything. No UI at all.
- Exit test: a filtered search and a refused tap read back as two rows differing in `reach`; an unwritten rating reads back as `unknown` and a recorded absence as `unrated`. Free today and impossible after the first release (see Migration & existing data).

**Stage 1 — the reader, with no screen.** _Done._

- Ships: `ReviewReader` as a `@ModelActor` in `FamilyStore` returning `ReviewWindow` — bounded fetches, `unreadable` counted, `deniedBy` resolved, `Coverage` computed against an empty summaries table. Annotation is a pure function over a window and an engine, in its own file, table-driven.
- Does not: touch the library, the catalog, or SwiftUI.
- Exit test: a store seeded with events of every origin and reason, including deliberately corrupt columns, round-trips all of them — counts, groups and `unreadable` — with no network and no device. This is where `PlaybackOrigin(stored:)` and `BlockReason(stored:)` get exercised for the first time.

**Stage 2 — the raw log, honestly labelled.** _Done._

- Ships: a per-kid review screen behind the gate, reachable for any kid without switching the active one; the played / searched / blocked views and the whole record; origins in a parent's words; the "as of" line and the device-clock caveat; the `unreadable` count; `Coverage`; per-kid delete of events and summaries.
- Does not: group, summarise, annotate, or show the library.
- Exit test: **not yet met.** It requires a real kid session on a device with MusicKit enabled, read alongside what actually happened. Everything under the screen is tested; the screen itself has been compiled and launched, not driven.

**Stage 3 — annotation and grouping.** _Done._

- Ships: `Annotated` on every row with its confidence shown as a third state; blocks grouped by artist with `reached` and `unseen` split and never summed; approve-from-report on a group, widening to the artist when one resolved; deny likewise.
- Does not: summarise a week, or suggest anything on its own.
- Exit test: a parent denies an artist and the same screen shows their kid's past plays of that artist marked as no longer playable — covered in `KidLibrary` for the shelf and in `FamilyStore` for the events. The fortnight-of-real-use half is field work, not a test.

**Stage 4 — the library, unfiltered.** _Done._

- Ships: `MergedLibrary.reviewed()`, favorites and playlists annotated, `LibraryOrigin` distinguishing what the kid chose from what arrived with the account, provider health, the unresolved count.
- Does not: let the admin edit a kid's favorites or playlists. Reading a child's shelf is oversight; editing it is taking their things.
- Exit test: an explicit song in the store is absent from `favorites()` and present in `reviewed()`, annotated `blocked(.explicitContent)` and marked as adopted rather than chosen. That pair is the proof the unfiltered rule holds, and it is the same scenario `The Kid's Library` stage 3 uses from the other side.

**Stage 5 — the week.** _Done._

- Ships: `WeeklySummary` derived on read — top artists by time, top songs by count, first-time-heard, blocks by artist, total listening, searches, reached-blocks — with the raw views one step behind it.
- Does not: notify, compare kids, or chart trends across weeks.
- Exit test: the derivation is covered, including a play whose lineage never resolved counting toward the total while grouping nowhere. Whether a parent can read one week and say what their kid was into is a measurement on a real week, not an assertion.

**Stage 6 — retention, once the window is decided.** _Not built, deliberately._

- Ships: the sweep, persisted summaries, and the window stated on the screen before it first takes effect.
- Does not: ship before the retention question is answered in writing. That answer does not exist, so neither does this stage.
- Already in place for it: `Coverage` renders today against an empty summaries table, and delete already takes summaries. The sweep is the only missing piece, and it is missing on purpose.
- Exit test: a swept week reads as summarised rather than empty; delete-everything leaves neither events nor summaries nor library rows — verified by inspecting the store, not the UI.

### Export is deliberately absent
No share sheet, no CSV, no print, no copy-all. A parent can read a child's history and cannot send it anywhere.

The project rule is that nothing leaves the device, and it is a legal position rather than an architectural preference. Strictly it constrains _us_ — our servers, third-party analytics, PII to anyone. A parent exporting their own family's data is a different act, and someone will reasonably argue it should be allowed.

It is still absent at v1, for three reasons.

**A share sheet is a route out of the app for a child's search history**, and the moment it exists the app's honest privacy claim becomes conditional on what a parent does next. "Nothing leaves the device" is a sentence worth being able to say without an asterisk, especially in front of App Review, and especially if the Kids Category is on the table.

**There is no established use for it.** Nobody has asked for a spreadsheet of their child's listening. Building the export before knowing what it is for means guessing at a format, and a format is a commitment.

**It cannot be un-shipped.** A parent who has exported has copies we cannot reach, which makes delete-everything a claim about our store rather than about their data. Adding export later is easy; removing it later is not.

Recorded as a decision rather than an oversight. If a real need appears — a custody arrangement, a school, a clinician — it comes back as its own question, with its own answer about what delete then means.

### What this deliberately does not do
**It does not edit the kid's library.** A parent can see every favorite and every playlist and cannot remove one. Reading a child's shelf is oversight; reaching in and deleting the playlist they made is taking their things, and the app has a policy engine for the case where a parent wants something gone — deny it, and the tile disappears from the kid's side while the row survives. That asymmetry is deliberate and it is the same one `The Kid's Library` already relies on.

**It does not notify.** No push, no badge, no weekly digest. There is no push story in this app, a favorite is not urgent, and a notification about a child's listening is the first feature here that would make a parent feel watched on the app's schedule rather than their own.

**It does not suggest.** No "kids who liked X", no "consider allowing this artist", no automatic widening. Every entry that reaches the allow or deny list is a parent tapping. Recommendation is one of the three MusicKit affordances the project refuses outright, and inventing our own from a child's history would be worse, not better.

**It does not compare kids, or compare a kid to anyone.** No leaderboards, no "more than average", no trend lines across weeks at v1. A report of one child, to their parent.

**It does not score, flag, or characterise.** No "concerning" label on a block group, no risk indicator, no summary sentence about the child. The screen shows what happened and the parent draws the conclusion. Anything else is us making a claim about a child from search terms, which is both beyond what the data supports and precisely the profiling posture that makes a Family Controls request fail.

**It does not hide anything from the parent** — which is the flip side of all of the above, and the only place the screen is maximal.

### What the kid is told
`Activity Log and Reports` carries the invariant that the kid is told they are being logged. This spec is where that promise gets a shape, because the thing they are told about is now a screen that exists.

**Once, in the kid's own onboarding, in their words**: _a grown-up can see what you listen to._ Not a running indicator, not a badge, not a per-search reminder — a child who is reminded on every screen that they are watched will use the app differently, and the app's whole premise is that exploring is safe here.

**Never surfaced as a live signal.** No "your parent is reading this now." Nothing on the kid's side changes when the review screen is open.

**Nothing about provider health, blocks, or the log ever reaches a kid screen** — already an invariant of `The Kid's Library`, restated because this is the component that generates all of it.

The honest framing, worth writing into the copy rather than deciding later: this is not surveillance that the child is unaware of, and it is not a negotiation either. A parent set up the walls, and the app tells the child that they exist and that someone can see through them.

### A parent must not appear in their child's report
The invariant reads _reading a report writes no event_, and that is the easy half. The hard half is everything **else** a parent does inside the passcode.

Building the report exposed a live instance of it. The admin's diagnostics screen — unrated frequency, ancestry resolution, how hard the over-fetch loop is working — ran its search through the kid's own `Session.search`, which logs the term and every filtered-out result, and played tracks through the kid's `Session.play`, which logs a refused item as `reach: .reached`. So a parent checking whether a rule worked appeared in the report as their child searching for that term and reaching for that song.

Nobody could have noticed before, because nothing read the log.

It is worse than a wrong number. The report's whole claim is _this is what one child did_, and a parent has no way to tell which rows are theirs. It puts words in a child's mouth, and it does it precisely to the parent who is most engaged — the one who checks their own rules.

**The rule: nothing a parent does writes to the kid's log.** Not searching, not playing, not favoriting, not previewing.

Enforced as a seam rather than a habit, for the same reason the unfiltered read is. Every admin surface goes through a small set of methods that reach the catalog and the player _without_ touching `EventLog`, and any new admin screen belongs there rather than reusing a kid path:

- `searchUnfiltered` — for building a list. No policy applied, nothing logged.
- `previewSearch` — the kid's real policy and the real engine, so a parent sees what their child would get. Nothing logged.
- `previewPlay` — still asks the engine and still refuses what the kid could not play, because the point is showing what the walls do. No block written on refusal, no play written on stop.

The awaited `Session.search` that used to exist has been **deleted rather than left unused.** It had exactly one caller, the one place that must not log, and an unused convenience method that quietly writes to a child's history is a loaded trap for whoever adds the next admin screen.

The one thing preview does not change is the engine. A parent's preview shows the kid's verdict and not a parent's — a preview that could play what the kid cannot would be a screen that lies about the walls it exists to demonstrate.

## Review
_Not reviewed._

## Open notes
_None._
