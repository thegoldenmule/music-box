# PolicyEngine

Decides what one kid may see or play. Pure logic — no MusicKit, no UI, no
network, no storage. That is the point: it is cheap to test and expensive to get
wrong.

```swift
let engine = PolicyEngine(policy: Policy(mode: .denyPlusAuto, entries: [.deny(badBand)]))

switch engine.evaluate(item) {
case .allowed:              play(item)
case .blocked(let reason):  log(reason); hideOrExplain(reason)
}
```

Build one engine per kid and reuse it across a page of results — the initializer
indexes the lists once so evaluating 25 search results does not rebuild them 25
times.

## Contract

Every surface asks this. Nothing else decides. The player calls `evaluate` again
immediately before playback starts rather than trusting that the UI only offered
allowed things. If the UI shows something the player then refuses, that is a UI
bug, not a safety failure.

The caller supplies ancestry (`Item.ancestors`, nearest first). The engine stays
synchronous and does no I/O; the catalog layer is the one place that knows how to
batch those lookups.

## Decisions that go beyond the spec

The spec left these open or implied. Each is a real behavioral choice, easy to
flip, and worth confirming.

**Deny applies in report-only too.** The rules are numbered "in order" with deny
first, so a deny survives a switch to level 3. But *The Idea* describes level 3
as "Everything. No walls." Those disagree. The current reading is the literal
one: a parent who explicitly denied a band probably still means it. Flip by
moving the `.reportOnly` case above the deny check in `evaluate`.

**Per-item override in level 2.** An allow on the item *itself* bypasses the
rating check; an allow on a container does not. So a parent can permit one
specific explicit song, while "allow this artist" still cannot silently permit
their next explicit release. The spec asked for a per-item override but the
storage schema has no override flag, so exact-match is standing in for one.

**Artists and playlists skip the rating check.** Neither carries a rating in
MusicKit — `Playlist` has no `contentRating` property at all. Without an
exemption, `UnratedBehavior.block` would hide every artist and playlist in the
catalog. They are containers: they may appear, and what is inside them is judged
track by track.

**Level 1 does not check ratings.** If a parent hand-picked something, they meant
it, explicit or not.

**A playlist is part of a track's lineage** when the track is played from it.
That is how an allow or deny on a playlist reaches its tracks, and it is scoped —
the same track reached by browsing its album is judged without the playlist.

## The unrated problem

`ContentRating` is `.clean` or `.explicit`, and the property is optional. `nil`
means "no rating available", not "safe" — so this is a three-state problem, not a
boolean.

`UnratedBehavior` is configurable rather than baked in because research question
3 is unanswered: nobody has measured how often MusicKit returns `nil`. If it is
rare, `.block` is right. If it is common, `.block` makes the app feel broken and
`.allow` makes the filter meaningless, which is what `.inheritFromAncestor` is
for. Default is `.block`.

Answer that question before picking a default for real. See `Tools/` for the
probe that should settle it.

## Tests

40 tests in 7 suites, grouped by rule. Table-driven where a rule has to hold
across modes or across unrated behaviors.

```sh
swift test
```
