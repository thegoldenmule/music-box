# CatalogKit

The only layer that imports MusicKit. Everything above it works in `CatalogItem`
and never sees a MusicKit type.

```swift
let catalog = FilteredCatalog(
    source: CachingCatalogSource(wrapping: MusicKitCatalogSource(), cache: InMemoryItemCache()),
    engine: PolicyEngine(policy: kidsPolicy)
)

let results = try await catalog.search(term: "dinosaurs", kinds: [.song, .album], limit: 25)
results.items     // what the kid may see
results.blocked   // what was filtered, with reasons, for the report
```

## Shape

| Type | Job |
| --- | --- |
| `CatalogSource` | Protocol. MusicKit in production, a stub in tests. |
| `MusicKitCatalogSource` | The adapter. Pure mapping, no decisions. |
| `FilteredCatalog` | Over-fetch loop plus policy. The interesting part. |
| `CachingCatalogSource` | Decorator that caches lookups and ancestry. |
| `CatalogAccess` | Authorization and subscription state, asked once and observed. |
| `LibrarySource` | Reads the account's library and matches it to the catalog. |
| `CatalogPlayer` | Plays one item. `MusicKitPlayer` in production. |

## The player is deliberately narrow

`CatalogPlayer` has `play`, `pause` and `stop`, and no `next`. It is here rather
than in the app for the same reason `CatalogSource` is: nothing above this layer
sees a MusicKit type.

`MusicKitPlayer` drives `ApplicationMusicPlayer` — the application queue, not the
system one, so a kid's listening never reorders a parent's Up Next in the Music
app and nothing queued there arrives here unvetted. It is also the reason the
macOS floor is 14.0.

It does not judge anything. The caller asks `FilteredCatalog.verdict(for:)`
immediately beforehand; this is the mechanism, not the authority.

One thing in it is unresolved: **which error MusicKit throws when Screen Time or
Apple Music's parental controls refuse playback.** The spec requires that case be
logged as `restrictedOutsideApp` and never attributed to a parent's own rule.
Until someone measures it on a device, those land in `CatalogError.underlying`,
which is wrong but is not a confident lie about which rule fired.

## Why the over-fetch loop exists

MusicKit search takes a term, types, a limit and an offset, and offers no way to
ask for clean results only. So filtering happens after the fact, which leaves
holes in a page — ask for 25 and get 12. `FilteredCatalog` asks for more than it
needs and pages until the page is full.

It reports two different kinds of "not enough":

- `reachedEnd` — the source ran out. An empty result genuinely means nothing
  matches.
- `gaveUpEarly` — we hit the retry cap while still short. We stopped looking;
  there may well be more. The UI should offer to keep going rather than claim an
  empty result.

Defaults are an over-fetch multiplier of 3, 3 retries, and a page ceiling of 25,
so at most four requests per search. The multiplier is a guess until someone
measures how common explicit and unrated results actually are —
`FilteredResults.requestCount` is there to make that measurable.

**25 is Apple Music's cap on search, not a tuning choice.** Asking for more is a
`400 / 40005 Invalid Parameter Value — Value must be an integer less than or
equal to 25`. The ceiling defaulted to 100 until the first device run, at which
point every single search failed. Nothing in this package caught it: the stub
served whatever it was asked for, and the packages build against macOS where
nothing contacts Apple Music at all.

That cap changes what over-fetching *is*. Once the caller's limit reaches 25 the
multiplier has no room left, and the only way to compensate for filtering holes
is to page — which is what `maxRetries` is for. The multiplier still earns its
keep at smaller limits, where one request can cover the need.

`MusicKitCatalogSource` clamps to `maxSearchLimit` as well, so a caller asking
for too much gets a short page rather than a failed search. It judges `hasMore`
against the clamped value: comparing against the asked-for limit would read a
full page of 25 as "fewer than 75, so the catalog is exhausted" and stop paging
after one request — turning a hard failure into a silently truncated one.

## Ancestry is batched on purpose

MusicKit does not return relationships with search results, so a song arrives
knowing nothing about its album or artist. The policy engine cannot block a song
for a denied artist without that lineage, so every result needs it before it can
be judged — and done one item at a time that is thirty round trips per page.

`resolveAncestry(for:)` takes the whole page at once. `FilteredCatalog` calls it
before evaluating anything, and `CachingCatalogSource` narrows each call to the
items that do not already have lineage.

## Library seeding

Lists are built by searching the catalog — `FilteredCatalog.search` — and any
catalog item can go on one, owned or not. **The library does not bound what a
parent may allow.**

`LibrarySource` is a shortcut on top of that, for a parent who already owns two
hundred suitable records and would rather not type two hundred searches. It saves
typing. The kid never browses here, and no library identifier is ever stored.

`resolveToCatalog` matches what the parent picked against Apple Music — songs on
ISRC, albums on UPC, one batched request each. On iOS and macOS 26.4+ those
requests also set `.findEquivalents`, so a regional pressing or reissue in
someone's library still matches the copy their storefront carries. Older systems
match more strictly and discard more. Anything with no match is discarded and
reported: `.noIdentifier` for a raw file, `.notInAppleMusic` for a coded release
Apple Music does not carry, `.unsupportedKind` for library artists and playlists,
whose filters expose no code that maps to the catalog.

A discard is not a refusal — the parent can still find that record through
catalog search, if Apple Music carries it at all. If it does not, we could never
have played it. Discards come back with the item attached rather than being
dropped, so the admin can show what did not make it and why.

**Why the rule matters.** If a library identifier could reach an allow or deny
list, a deny on an artist would not reach that artist's tracks — no shared
namespace to match on, no catalog ancestry to walk. Resolving to the catalog
first leaves exactly one namespace, so every rule reaches everything and
`PolicyEntry` needs no scope field.

Resolved items arrive with ancestry already attached: the match request asks for
relationships anyway, so a seeded song is immediately judgeable against a denied
artist.

## What is not tested here

`MusicKitCatalogSource`, `MusicKitLibrarySource` and `MusicKitAccess` compile
against the real SDK and are otherwise unverified — they need a device, a
subscription, and a signed-in account. Everything else runs in-process against
`StubCatalogSource` and `StubLibrarySource`: 31 tests covering the filter, the
loop, the caps, the cache, and the seeding rules.

```sh
swift test
```

Two things in the adapter are inference rather than knowledge, flagged for the
first real-device run:

1. `hasMore` is inferred from getting back a full page, since MusicKit gives no
   total count. Overshooting by one empty request beats stopping early and
   claiming a search found nothing.
2. ISRC and UPC matching assumes library items expose those codes in practice.
   The properties exist on `Song` and `Album`, but how often they are populated
   for library content — and how often a match actually lands — is exactly what
   the first real-device run needs to measure. Measure it on a pre-26.4 system
   too: `.findEquivalents` is not there to soften the result.
