# Policy Engine (superseded draft)

**Status:** active

## Body
The heart of the app. One component that answers one question: _can this kid see or play this thing right now?_ Everything else asks it. Nothing else decides.

## Why it's one thing

The tempting shortcut is to filter search results in the search screen and check again in the player. That's how you end up with two rules that disagree and a kid who finds the gap. Instead: one function, called from every surface, and the player calls it again immediately before playback starts. If the UI ever shows something the player then refuses, that's a bug in the UI, not a safety failure.

## What it takes in

- The kid's mode: allow-only, deny-plus-auto, or report-only.
- The kid's allow list and deny list — entries by type and catalog ID.
- The item being judged: its ID, type, content rating, and its parents (a song's album, an album's artist).

## What it gives back

Not a boolean. A verdict with a reason, because the reason is what the report is made of and what the kid's "why can't I play this" message comes from.

```swift
enum Verdict {
    case allowed
    case blocked(Reason)
}

enum Reason {
    case notOnAllowList       // level 1, parent never added it
    case deniedByParent(id)   // level 2, explicit deny — name what matched
    case explicitContent      // level 2, contentRating == .explicit
    case unrated              // level 2, contentRating == nil — see open question 3
}
```

## The rules, in order

1. **Deny always wins.** If the item or any of its parents is on the deny list, it's blocked, full stop. A parent who denies an artist and separately allowed one of their songs meant the deny.
2. **Report-only allows everything.** Log it, return allowed. No exceptions, or the mode isn't what we said it was.
3. **Allow-only requires a match.** The item, or one of its parents, has to be on the allow list. Allowing an artist covers their albums and songs. Allowing an album covers its tracks.
4. **Deny-plus-auto checks the rating.** Explicit is blocked. Clean passes. Unrated is the open question — pick one behavior and make it configurable rather than baking in a guess.

## The parts that will bite

- **Ancestry costs requests.** Judging a song by its album's rating means we need the album, which search may not have returned. Batch these lookups and cache hard, or a filtered search page turns into thirty round trips.
- **Playlists have no rating.** There is no verdict for a playlist as a whole in level 2. A playlist is allowed to appear, and then every track inside gets judged individually as it comes up. Blocked tracks get skipped silently rather than stopping the queue.
- **Allowed does not mean unfiltered.** In level 2, an explicitly allowed artist should probably still have their explicit tracks filtered, unless the parent overrides per-item. Otherwise "allow this artist" quietly becomes "allow anything they ever release."
- **Explicit-clean pairs.** The catalog often carries both versions of the same song. When we block the explicit one, we should offer the clean one rather than pretending the song doesn't exist.

## Testing

This is the one component that deserves exhaustive tests before anything else exists. It's pure logic with no UI and no network, so it's cheap to test and expensive to get wrong. Table-driven: every combination of mode, list membership, ancestry, and rating, including the nil cases.

## References
_None._

## Child pages
_None._
