# Spec: Policy Engine

**Status:** restated

## Sections
### Motivation
We want a single place for all content decisions to be made. That is the policy engine.

### Overview
The policy engine answers the question of which content is allowed and which is not. All systems use this engine to make content decisions.

**A single authority with a single entry point.** The player asks  before playback.

**No I/O.** The engine is a pure function over data the caller supplies, including the item's ancestry. That keeps it exhaustively testable with no network, no subscription and no device.

It returns a verdict with a reason. The reason is what the activity report is built from and what the kid is told.

### Data model & types
```swift
/// The three levels, set per kid rather than per family.
enum SandboxMode { case allowOnly, denyPlusAuto, reportOnly }

enum ItemKind { case artist, album, playlist, song }

/// Kind is part of identity: MusicKit identifiers are unique only WITHIN a
/// type, so matching on the raw string alone would let an album id collide
/// with a song id and quietly widen a parent's list.
struct CatalogID: Hashable { let kind: ItemKind; let rawValue: String }

/// Mirrors MusicKit exactly, including the optional, which is load-bearing:
///   .clean    — rated, no explicit lyrics
///   .explicit — rated explicit
///   nil       — NO RATING AVAILABLE. Not a synonym for .clean.
enum ContentRating { case clean, explicit }

/// What a nil rating means in denyPlusAuto. Configurable rather than baked in
/// because the real-world frequency of nil is still unmeasured.
///   .allow               — treat unrated as safe
///   .block               — treat unrated as explicit (current default)
///   .inheritFromAncestor — borrow the nearest rated container, else block
enum UnratedBehavior { case allow, block, inheritFromAncestor }

struct PolicyEntry: Hashable {
    enum Kind { case allow, deny }
    let kind: Kind
    let id: CatalogID
}

struct Policy {
    let mode: SandboxMode
    let entries: [PolicyEntry]      // allow and deny in one list, distinguished by kind
    let unratedBehavior: UnratedBehavior
}

/// A container the item sits inside. `rating` is ALWAYS nil for artists and
/// playlists — neither carries one in the catalog.
struct Ancestor { let id: CatalogID; let rating: ContentRating? }

/// `ancestors` is ordered NEAREST FIRST: a song's album, then its artist, plus
/// the playlist it is being played from when there is one.
/// An EMPTY array is legal and ambiguous: it means either "no containers" or
/// "lineage not resolved yet", and the engine cannot tell which
/// (see Failure & concurrency semantics).
struct Item { let id: CatalogID; let rating: ContentRating?; let ancestors: [Ancestor] }

enum Verdict { case allowed; case blocked(Reason) }

enum Reason {
    case notOnAllowList              // allowOnly, no match on the item or its ancestry
    case deniedByParent(CatalogID)   // carries WHICH entry matched, for the report
    case explicitContent             // rating == .explicit
    case unrated                     // rating == nil and the behaviour says block
}
```

### Algorithm
```text
evaluate(item, policy) -> Verdict

1. DENY CHECK — runs in every mode, before the mode is consulted at all.
   1.1 if policy.denied contains item.id
           -> blocked(.deniedByParent(item.id))
   1.2 else walk item.ancestors nearest-first; on the first whose id is denied
           -> blocked(.deniedByParent(thatAncestor.id))

2. if policy.mode == reportOnly
       -> allowed                      // no walls; the caller still logs it

3. if policy.mode == allowOnly
   3.1 if policy.allowed contains item.id            -> allowed
   3.2 if any ancestor.id is in policy.allowed       -> allowed
   3.3 otherwise                                     -> blocked(.notOnAllowList)
   // deliberately no rating check: a hand-picked item was picked on purpose

4. policy.mode == denyPlusAuto
   4.1 if policy.allowed contains item.id EXACTLY    -> allowed
       // the per-item override. An allow on an ANCESTOR does NOT land here,
       // so "allow this artist" cannot permit their next explicit release.
   4.2 if item.id.kind is .artist or .playlist       -> allowed
       // containers carry no rating; what is inside them is judged one at a time
   4.3 r := item.rating
       if r == nil and policy.unratedBehavior == .inheritFromAncestor:
           r := rating of the nearest ancestor that has one, else nil
   4.4 switch r:
         .clean    -> allowed
         .explicit -> blocked(.explicitContent)
         nil       -> policy.unratedBehavior == .allow ? allowed
                                                       : blocked(.unrated)
```

### Invariants & limits
- Deny is evaluated before the mode, so a deny applies in **every** mode, including report-only.
- A deny on a container reaches everything beneath it.
- When both an item and one of its containers are denied, the item's own id is the one reported.
- Report-only blocks for no reason other than a deny.
- Allow-only never consults a content rating.
- In deny-plus-auto, an allow on the item itself suppresses the rating check; an allow on an ancestor does not.
- Artists and playlists are never blocked by rating, because neither carries one.
- A `nil` rating is never treated as `.clean`. Only `UnratedBehavior.allow` lets an unrated item through.
- `inheritFromAncestor` takes the nearest rated ancestor, and blocks when no ancestor is rated either.
- `ancestors` is ordered nearest-first, and both deny reporting and rating inheritance depend on that order.
- `evaluate` is pure, total and deterministic: same inputs, same verdict; no I/O, no clock, no randomness, no throwing path.
- The engine holds no mutable state and is safe to share across isolation domains.
- Cost is O(number of ancestors) per call; list membership is O(1), indexed once when the engine is constructed rather than per item.

### Failure & concurrency semantics
**The engine itself cannot fail.** It performs no I/O, has no dependency that could be missing, and every combination of inputs yields a verdict. There is no error case and nothing to retry.

What can be wrong is its input, and one case matters: an empty `ancestors` array. Nothing distinguishes "this item has no containers" from "lineage was never resolved", and the engine cannot tell them apart. It judges what it is handed.

The consequence is **asymmetric**, and this is the sharp edge of the whole component:

- Deny **fails open**. An unresolved song by a denied artist is allowed, because the artist is not in the ancestry to match against.
- Allow-only **fails closed**. An unresolved song on an allowed album is blocked, because the album is not there to match either.

So a verdict computed on an item with empty ancestors is **provisional** for anything that can have containers — songs and albums. It is final for artists, which have none, and for playlists, which are judged as containers.

Closing that gap is the caller's job, not this component's. `FilteredCatalog` resolves ancestry for a whole page before evaluating any of it, and the player re-evaluates immediately before playback, resolving lineage first when it is missing.

**Concurrency.** The engine is an immutable value with no shared state; concurrent evaluations cannot interfere. A `Policy` is fixed once the engine is constructed, so changing a kid's settings means building a new engine — a page of results in flight finishes under the policy it started with rather than tearing between two.

### Data dependencies
Two inputs, arriving by different routes and on different timescales.

**The kid's policy** — mode, entries, unrated behaviour. Read from local storage. Available synchronously at launch, cheap to re-read, no network. There is no window: the data is there before anything can ask. An edit made in the admin takes effect on the next engine constructed, not on evaluations already running.

**The item** — its id, rating and ancestry. From CatalogKit, over the network.

Those two parts of an item do not arrive together, and that is the one real dependency gap in this component:

- **Rating** arrives with the item, in the search response itself.
- **Ancestry does not.** MusicKit returns no relationships with search results, so lineage takes a second, batched request.

Behaviour in the window before ancestry lands is stated in Failure & concurrency semantics: the engine judges on what it has, deny fails open, and the verdict is provisional. The rule that closes the window lives in the caller — nothing evaluates a song or album until its lineage has either been resolved or definitively come back empty.

### Migration & existing data
**Nothing to migrate.** No policy data exists anywhere: no shipped build, no users, no persisted lists.

What is worth settling now, because it is free now and expensive later, is how the unrated behaviour is stored.

`UnratedBehavior` defaults to `.block`, and that default is a guess pending measurement. If each kid's value is persisted as a concrete case from the first release, then changing our recommended default later affects only newly created kids, and existing ones keep the behaviour their parent effectively agreed to. If instead the field is absent and a constant is consulted at evaluation time, shipping a different default silently changes what every existing kid can reach — in both directions, with no notice to anyone.

So: persist `unratedBehavior` per kid as an explicit value from day one, even while every kid is given the same one. The same goes for `mode` — store the case that was chosen, never one derived or defaulted at read time.

This is a constraint on the storage layer that only makes sense from here, which is why it is recorded here.

### Staged plan
**Stage 1 — the engine, standalone.** _Done._

- Ships: the types, `evaluate`, and a table-driven suite over every combination of mode, list membership, ancestry depth and rating, including the nil cases. Pure logic, so it is cheap to test and expensive to get wrong — it gets tested before anything else exists.
- Does not: touch MusicKit, persist anything, or have a UI.
- Exit test: the suite passes on a clean checkout with no network and no device. 40 tests, currently green.

**Stage 2 — wired to the catalog.**

- Ships: evaluation applied to live search results, with ancestry resolved in batch before anything is judged.
- Does not: offer the parent any per-item override, or handle library content.
- Exit test: a deny on an artist blocks that artist's songs in real search results on a device.

**Stage 3 — the unrated decision.**

- Ships: `UnratedBehavior` chosen from measurement rather than guess, and persisted per kid.
- Does not: expose the choice as a user-facing setting unless the measurement shows it has to be.
- Exit test: the sampled frequency of nil ratings is written down, and the chosen default is justified by that number rather than by caution.

**Stage 4 — a real per-item override, only if needed.**

- Ships: an explicit override flag on `PolicyEntry`, if exact-match turns out to be the wrong signal in practice.
- Does not: ship at all if exact-match holds up. This stage is expected to be dropped.
- Exit test: a parent can allow one explicit song by an otherwise-filtered artist without widening anything else — or a written note that exact-match already does this and the stage is closed unbuilt.

## Review
_Not reviewed._

## Open notes
_None._
