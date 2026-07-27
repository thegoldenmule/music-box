# Spec: Kid Player

**Status:** restated

## Sections
### Motivation
The player needs to be simple and intuitive to use for kids.

### Overview
This is the music player the kid uses.

Blocked items are hidden rather than shown. The only block a kid ever sees is a filtered track inside an allowed playlist, and that one gets a plain sentence.

Controls are play, pause and skip. Autoplay past the end of the queue is off.

The player asks the policy engine again immediately before playback rather than trusting that the UI only offered allowed things.

### Data model & types
```swift
enum PlayerScreen {
    case home                  // level 1: the allow list. levels 2 and 3: recents.
    case search                // absent entirely in level 1
    case browse(CatalogID)     // an artist's albums, an album's tracks
    case nowPlaying
}

struct PlaybackState {
    let current: QueueEntry?   // nil means nothing loaded, not paused
    let isPlaying: Bool
    let queue: [QueueEntry]    // already filtered; blocked entries never enter
}

struct QueueEntry {
    let item: CatalogItem
    let origin: Origin
}

/// Where a play came from. A playlist origin puts the playlist in the track's
/// lineage, which is how an allow or deny on a playlist reaches its tracks.
enum Origin {
    case home
    case search(term: String)
    case browse(CatalogID)
    case playlist(CatalogID)
}
```

### Algorithm
**Playing something.**

```text
play(item, origin)

1. verdict := catalog.verdict(for: item)     // resolves lineage if missing
2. if blocked:
     log it
     playlist entry -> show the message; otherwise refresh the surface
     stop
3. queue := [item], or the playlist's tracks when origin is a playlist,
            each carrying the playlist in its lineage
4. play, and log the play
```

**Advancing in a playlist.**

```text
onAdvance(next)

1. evaluate next            // lineage attached at enqueue
2. if blocked: log it, skip to the following entry, repeat
3. if the queue runs out that way, stop
```

**Launch.**

```text
1. kid or shared device -> the active kid's home
2. never show a kid chooser
3. no subscription -> say so, rather than an empty catalog
```

### Invariants & limits
- Every playback is preceded by a fresh verdict, taken immediately before play.
- In levels 1 and 2, a blocked item is never rendered as something tappable that then refuses.
- The only visible block is a filtered track inside an allowed playlist.
- A visible block is explained in plain words, with no error code and no mention of the rule that fired.
- The controls are play, pause and skip. Nothing else.
- Autoplay past the end of the queue is off. When the queue ends, playback stops.
- No screen links out of the app.
- Nothing about subscriptions or purchases appears on the kid's side.
- Search is absent from the interface in level 1, not present and empty.
- The app launches into the player, never a chooser.
- Switching kids requires the parental gate.
- A blocked playlist entry is skipped, never halting the queue.
- Plays, search terms and visible blocks are logged.

### Failure & concurrency semantics
**Blocked from outside.** Screen Time or Apple Music's own parental controls can refuse an explicit track beneath us. The kid sees the ordinary message; the log records `restrictedOutsideApp` so the parent's report names the real cause.

**Policy changed mid-session.** The current track finishes. The change lands on the next evaluation — the next tap or the next queue advance. Cutting out mid-song looks like a fault rather than a rule.

**Item disappeared.** Playback fails, the entry is skipped, the surface refreshes.

**Subscription lapsed.** Playback stops. The kid gets a plain message, the parent gets the reason. There is no offline fallback.

**Offline.** The app does not work, and says so.

**Concurrency.** One player, one queue, one active kid. Playback state is main-actor. Logging is fire-and-forget and never delays playback.

### Data dependencies
**The active kid's policy** — local, read before the first screen draws. A device with no kid configured shows setup, not an empty player.

**Filtered results** — from `FilteredCatalog`, over the network. Every browse and search surface waits on them. Show a loading state, not an empty one.

**Artwork** — by URL, per tile, after the item itself.

**Playback** — `ApplicationMusicPlayer`, which also needs an active subscription. Checked before the player is offered, so a kid never taps a song and gets a subscription message.

**Device role and active kid** — local, set during setup, read before anything else.

### Migration & existing data
**Nothing to migrate.** No kid has used the app, so there is no playback state or recents.

Two things to get right in the first release.

**Recents are filtered at render time**, not stored as a ready-made list of allowed items. A kid's recents can contain something a parent has since denied, and a stale list would leave it sitting on the home screen.

`origin`** is logged from the start.** It costs one field now. Added later, every historical event lacks it.

### Staged plan
**Stage 1 — play one thing.**

- Ships: home as the allow list, now playing with play, pause and skip, and the pre-playback re-check.
- Does not: search, browse, playlists, recents.
- Exit test: a kid taps a tile and hears the song; an item denied in the admin refuses to start and is logged.

**Stage 2 — browse and search.**

- Ships: artist and album browse, the search field for levels 2 and 3, loading states.
- Does not: playlists.
- Exit test: a search with explicit results shows only clean ones, and the blocked count reaches the parent's report.

**Stage 3 — playlists.**

- Ships: playlist playback, judged per track, skipping blocked entries.
- Does not: let a kid build or edit a playlist.
- Exit test: a playlist containing an explicit track plays through without stopping, and the skip appears in the report.

**Stage 4 — Mac.**

- Ships: the same screens on macOS 14+.
- Does not: any lockdown; there is none available on the Mac.
- Exit test: playback works on Mac.

## Review
_Not reviewed._

## Open notes
_None._
