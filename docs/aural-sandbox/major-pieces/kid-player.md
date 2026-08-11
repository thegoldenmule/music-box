# Spec: Kid Player

**Status:** restating

## Sections
### Motivation
The player needs to be simple and intuitive to use for kids.

### Overview
This is the music player the kid uses.

Blocked items are hidden rather than shown. The only block a kid ever sees is a filtered track inside an allowed playlist, and that one gets a plain sentence.

Controls are **play**, **pause**, **skip** and **seek**. Autoplay past the end of the queue is off.

Seek was added after the first build and is the only control ever added to the original three. It earns its place by the test the others pass: it is not a door. Dragging the playhead reaches nowhere the verdict that started the track did not already allow. There is still no shuffle, no repeat, no next-up list, no radio and no autoplay.

The player has two faces. A **bar**, always present under whatever the kid is browsing, carrying the song and the controls. A **full-screen player**, opened by tapping the song in the bar, carrying the same controls at a larger size plus the scrubber.

From the full-screen player the kid can reach **the record and the artist**: the cover opens the album and the name beneath the title opens the artist. Nothing was added to the screen to carry these — the two largest things already on it became the two links. Both are resolved and judged before they are drawn, so a denied artist is plain text and a denied album is a picture that does nothing when tapped. Neither lands anywhere new: album and artist pages are already reachable from search and from every shelf, and each filters its own contents on arrival.

The player asks the policy engine again immediately before playback rather than trusting that the UI only offered allowed things.

### Data model & types
```swift
enum PlayerScreen {
    case home                  // level 1: the allow list. levels 2 and 3: recents.
    case search                // absent entirely in level 1
    case browse(CatalogID)     // an artist's albums, an album's tracks
    case nowPlaying            // the bar, always present
    case nowPlayingFull        // opened by tapping the song in the bar
}

struct PlaybackState {
    let current: QueueEntry?   // nil means nothing loaded, not paused
    let isPlaying: Bool
    let queue: [QueueEntry]    // already filtered; blocked entries never enter

    // For the scrubber. `position` is where the playhead is; `duration` is nil
    // when the catalog did not say, and the scrubber is then absent rather than
    // guessing at an end.
    let position: TimeInterval
    let duration: TimeInterval?
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

/// The record and the artist behind the song, once judged. Either may be nil
/// because the catalog had none or because the engine refused it — the screen
/// does not distinguish, and draws the un-linked form for both.
struct Lineage {
    let album: CatalogItem?
    let artist: CatalogItem?
}
```

**The player interface gains two members** and one changes meaning:

```swift
protocol CatalogPlayer {
    func seek(to seconds: TimeInterval) async

    /// Where the playhead is — for drawing, not for reporting.
    var playbackTime: TimeInterval { get }

    /// Seconds actually HEARD, which is no longer the same number. Banked on
    /// every seek and accumulated across them, so dragging back to the start
    /// does not erase the minute just listened to. May exceed the duration.
    var playbackSeconds: Int { get }
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
- The controls are play, pause, skip and seek. Nothing else.
- Seek does not re-judge. The verdict that started the track still stands, for the same reason resume does not re-judge: cutting out mid-song reads as a fault rather than a rule.
- Autoplay past the end of the queue is off. When the queue ends, playback stops.
- No screen links out of the app. The full-screen player links to the album and the artist, which are screens _inside_ it; nothing reaches a browser, the Music app, or a store.
- Nothing the player links to is reachable only from the player. The cover and the artist name are shortcuts to screens already reachable from search and from every shelf, so the player widens no one's reach — it shortens a path.
- Every link out of the player is judged before it is drawn. A denied artist renders as their name in plain text; a denied album renders as a cover that is not a button. Neither is shown as an error, and neither is a link onto an empty page.
- Time heard is not playhead position. Seeking breaks the correspondence between them, so the play event records time actually heard, accumulated across seeks. It may exceed the track's duration — a chorus played four times was heard four times.
- Artwork is held in memory only and never written to disk. §3.3.6(D) forbids downloading MusicKit Content; only the URL is ever stored.
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

### The bottom bars, and why their room is reserved twice
The kid's app carries two permanent controls at the bottom of every screen: the now-playing bar, and below it the row holding the home button and the search field. Both are drawn **once**, in a single `safeAreaInset(edge: .bottom)` applied to the one `NavigationStack` in `KidHomeView` — outside the stack rather than inside it, because a `searchable` belongs to the navigation container it is applied to and draws on that container's _root_, so a field applied inside vanished the moment a kid opened an album. Eight screens deep is exactly where both controls are wanted.

They are one inset and not two. An inset inside the stack and another outside it do not know about each other, and the two bars were drawn over the top of one another until they were stacked in a single `VStack` where the layout does the arranging.

## A `safeAreaInset` on a `NavigationStack` does not reach what is pushed onto it

**Verified on device, Xcode 26.6 / iOS 26.** A `safeAreaInset` (and the iOS 26 `safeAreaBar`) applied to a `NavigationStack` insets the stack's **root** and nothing else. Every destination reached through `navigationDestination` lays out as if the bottom of the window were empty. This is Apple's bug, filed as **FB23732628**; it is not a misuse of the modifier, and there is no argument or ordering that fixes it.

The symptom is quiet and easy to misread as a styling problem: the home screen is correct, and every screen past it — artist, album, playlist, library, history, browse — draws its last rows underneath the now-playing bar and cannot be scrolled clear of it. Nothing warns, nothing logs, and it only shows on the screens a kid reaches by tapping something.

## What the app does instead

The bars stay drawn once. The **room** for them is reserved twice, and it has to be:

- The inset that draws them measures its own height through a `GeometryReader` in its background, published as a `BarHeightKey` preference into `barHeight`. Measured, not a constant: the now-playing bar comes and goes with what is playing, grows a line when it has something to say, and the search field is absent in level 1 — four different numbers, and none of them survives a bar gaining a control.
- The single `navigationDestination` closure — the one seam every pushed screen in the kid's app passes through — wraps its content in `.safeAreaInset(edge: .bottom) { Color.clear.frame(height: barHeight) }`.

Three choices in that line are load-bearing:

- **A clear spacer, not a second copy of the bars.** Height is the only part of them a pushed screen needs, and drawing them again is exactly the doubling that moved them out of the stack in the first place.
- **A **`safeAreaInset`**, not **`padding`** or **`contentMargins`**.** It has to be the same _kind_ of thing the root gets. A scroll view insets its content by it, and a screen that is not scrolling — a "Nothing to play here", a spinner, a failure state — centers itself in what is left rather than behind the bar. `contentMargins` reaches only the first of those.
- **The bars' height alone.** The window's own bottom inset is already in these screens' safe area; adding it again would reserve the home indicator twice.

Because it sits at the seam rather than on the screens, a screen added later gets it without knowing it exists. That is the property worth keeping: the previous arrangement repeated the bars on all eight kid screens, and every one of those repeats was a chance for the bug they were consolidated to fix.

## What this does not cover

Sheets — the admin gate and the new-playlist sheet — present modally over the bars rather than under them, and need none of this. `SearchView`, the diagnostics screen inside the admin sheet, applies its own inset directly to a view rather than to a stack, where the modifier works as documented.

**Unverified:** `LibraryView` is the only destination that also uses `.searchable`, and on the iOS 26 SDK that field is placed at the bottom by the navigation container. Whether it sits above the reserved space or fights with it has not been looked at on device.

## Review
_Not reviewed._

## Open notes
_None._
