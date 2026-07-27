# Spec: Catalog and Search Layer

**Status:** restated

## Sections
### Motivation
MusicKit hands back whatever the catalog holds. `MusicCatalogSearchRequest` takes a term, types, a limit and an offset, and there is no parameter meaning "clean results only" — the filter does not exist at the API. Any app wanting a filtered catalog has to filter after the fact, which punches holes in every page: ask for 25 and get 12.

The data needed to filter does not arrive with the results either. A song comes back knowing its own rating but nothing about its album or its artist, so a deny on an artist cannot be applied to the songs a search just returned. Fetching lineage one item at a time turns a single page into thirty round trips.

And if every part of the app called MusicKit directly, two things would follow. MusicKit's types would spread through the codebase, so swapping the backend later would mean touching everything. And the policy engine would need a network, a subscription and a device to test — which is exactly the component that most needs to be testable without them.

### Overview
The only layer that imports MusicKit. Everything above it works in `CatalogItem` and never sees a MusicKit type.

Three ideas hold it together.

**A protocol seam.** `CatalogSource` is what the app depends on; `MusicKitCatalogSource` implements it in production and a stub implements it in tests. The adapter is deliberately mechanical — mapping in, mapping out, no decisions — so the parts worth testing are the parts that can be.

**An over-fetch loop.** Because filtering happens after the fact, the layer asks for more than it needs and pages until the page is full, then reports honestly whether it ran out of results or merely stopped looking.

**Ancestry resolved in batch, before anything is judged.** One request per page, not one per item.

The account's library rides alongside as a seeding shortcut for the admin. It is matched to the catalog before anything is stored, so the rest of the app only ever deals in catalog identifiers.

### Data model & types
```swift
/// The boundary type. ALWAYS a catalog item — library content reaches the app
/// only by being resolved to its catalog equivalent first.
struct CatalogItem: Identifiable {
    let id: CatalogID              // from PolicyEngine; kind + raw string
    let title: String
    let subtitle: String?          // artist name for song/album, curator for a
                                   // playlist, nil for an artist
    let artworkURL: URL?           // referenced, never copied into our storage
    let rating: ContentRating?     // nil = catalog gave none, NOT "clean"
    let ancestors: [Ancestor]      // nearest first; EMPTY straight out of search
}

/// One page from a source, unfiltered.
struct CatalogPage {
    let items: [CatalogItem]
    let hasMore: Bool              // INFERRED from a full page: MusicKit gives no
                                   // total count. See Failure & concurrency semantics.
}

struct BlockedItem { let item: CatalogItem; let reason: Reason }

struct FilteredResults {
    let items: [CatalogItem]       // capped at the requested limit
    let blocked: [BlockedItem]     // kept, never dropped — the report needs them
    let reachedEnd: Bool           // the source ran out; an empty result is real
    let gaveUpEarly: Bool          // hit the retry cap while still short
    let requestCount: Int          // for tuning the multiplier against real searches
}

struct Configuration {
    var overFetchMultiplier: Int = 3   // >= 1
    var maxRetries: Int = 3            // >= 0; total requests <= 1 + maxRetries
    var maxPageSize: Int = 100         // ceiling on one request
}

/// Library-side, and SHORT-LIVED: exists only inside the admin's seeding flow.
/// `id` is a library identifier and is never persisted anywhere.
struct LibraryItem: Identifiable {
    let id: String
    let kind: ItemKind
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let isrc: String?              // songs; the handle we match on. nil = raw file
    let upc: String?               // albums; ditto
}

enum DiscardReason {
    case noIdentifier      // no ISRC/UPC — ripped CD, personal upload, raw file
    case notInAppleMusic   // had a code, no catalog match
    case unsupportedKind   // library artists and playlists carry no matchable code
}

struct DiscardedItem { let item: LibraryItem; let reason: DiscardReason }
struct LibraryImport { let resolved: [CatalogItem]; let discarded: [DiscardedItem] }

enum AuthorizationStatus { case notDetermined, denied, restricted, authorized }

struct SubscriptionState {
    let canPlayCatalogContent: Bool
    let canBecomeSubscriber: Bool
    let hasCloudLibraryEnabled: Bool   // false => library reads return NOTHING
}

enum CatalogError: Error {
    case notAuthorized(AuthorizationStatus)
    case noSubscription
    case cloudLibraryDisabled
    case offline
    case restrictedOutsideApp     // Screen Time or Apple Music parental controls
    case itemUnavailable(CatalogID)
    case underlying(String)
}
```

### Library seeding
Building a list means searching the Apple Music catalog. That is the main path and nothing limits it — any artist, album, playlist, or song in the catalog can go on an allow or deny list, whether or not the parent owns it.

The library is an optional shortcut on top of that. They can specify playlists, albums, artists, or songs from their own library or playlists to allow for the kid.

### What the parent sees
Discards are shown, not silently dropped, with the reason: no recording code, or no Apple Music release. A parent who expected their whole library to seed should be able to see what did not make it — otherwise the gap looks like a bug in our matching rather than a gap in the catalog.

### How the matching works
- **Songs** match on ISRC, the recording code. `SongFilter` exposes it, so one batched request resolves however many the parent selected.
- **Albums** match on UPC, the product code, the same way.
- **Artists and playlists cannot be matched.** Their filters carry only a library identifier, nothing that maps to the catalog. A parent reaches an artist by seeding one of their songs or albums and widening from there — the resolved item already carries its catalog artist, because the match request asks for relationships anyway. Or, more simply, by searching for the artist directly.

Two requests total per seed, however many items were picked. On iOS and macOS 26.4+ they also set `.findEquivalents`, so a regional pressing or reissue still matches the copy the storefront carries.

### What actually gets stored
Whichever route the parent took, a list entry is an Apple Music catalog item. So anything picked from the library gets matched to the catalog first, and anything with no catalog equivalent is discarded rather than stored.

Discarding is not a restriction on the parent either. Anything that fails to match can still be found and added through catalog search, assuming it is on Apple Music at all. If it is not on Apple Music, we could not have played it regardless.

### Algorithm
**Filtered search — the over-fetch loop.**

```text
search(term, kinds, limit) -> FilteredResults

1. if limit <= 0 or term is empty or kinds is empty
       -> empty result, requestCount 0, reachedEnd true   // make no request at all
2. pageSize := min(limit * overFetchMultiplier, maxPageSize)
3. allowed := [], blocked := [], offset := 0, requests := 0, retries := 0
4. while allowed.count < limit:
   4.1 page := source.search(term, kinds, pageSize, offset); requests += 1
   4.2 offset += page.items.count       // advance by what came back, not what was asked
   4.3 resolved := source.resolveAncestry(page.items)   // ONE call for the whole page
   4.4 for each item in resolved:
         verdict := engine.evaluate(item.policyItem)
         .allowed         -> allowed.append(item)
         .blocked(reason) -> blocked.append((item, reason))
   4.5 if page.items is empty or not page.hasMore:
           reachedEnd := true; break
   4.6 if allowed.count >= limit: break
   4.7 retries += 1; if retries > maxRetries: break
5. -> FilteredResults(
        items:        first `limit` of allowed,
        blocked:      blocked,
        reachedEnd:   reachedEnd,
        gaveUpEarly:  allowed.count < limit AND not reachedEnd,
        requestCount: requests)
```

**Library seeding — resolve to catalog.**

```text
resolveToCatalog(items) -> LibraryImport

1. partition items:
     song with isrc      -> songsByISRC[isrc]
     song without isrc   -> discard(.noIdentifier)
     album with upc      -> albumsByUPC[upc]
     album without upc   -> discard(.noIdentifier)
     artist or playlist  -> discard(.unsupportedKind)
2. if songsByISRC not empty:
     request := catalogResourceRequest(Song, matching isrc, memberOf keys)
     request.properties := [.albums, .artists]      // lineage in the same call
     if OS >= 26.4: request.options := [.findEquivalents]
     for each returned song: record match; resolved.append(catalogItem(song))
3. same shape for albumsByUPC, matching on upc, properties [.artists]
4. for every code with no returned match -> discard(.notInAppleMusic)
5. -> LibraryImport(resolved, discarded)
```

Two requests total across steps 2 and 3, however many items the parent selected.

### Invariants & limits
- A single request is `min(limit × overFetchMultiplier, maxPageSize)` and never exceeds `maxPageSize`.
- One search issues at most `1 + maxRetries` requests — four by default.
- A degenerate call (empty term, zero limit, or no kinds) issues **zero** requests.
- Returned items never exceed the requested limit.
- `reachedEnd` and `gaveUpEarly` are mutually exclusive: the first means the source ran out, the second means we stopped looking. An empty result carrying `gaveUpEarly` does not mean nothing matched.
- Ancestry is resolved exactly once per page, before any item on that page is judged — never per item.
- Nothing is judged before its lineage is resolved or has definitively come back empty.
- Blocked items are always returned, never discarded; the activity report is built from them.
- Item lookups and ancestry are cached; **searches are not**, because a stale search page is worse than a slow one.
- Ancestry resolution preserves the source's ordering — search relevance _is_ the ordering.
- Every identifier that leaves this layer is a catalog identifier. No library identifier is ever persisted.
- Library resolution costs two catalog requests regardless of how many items were selected.
- Library artists and playlists are always discarded: their filters expose no code that maps to the catalog.
- The library never bounds what a parent may allow — it is a shortcut over catalog search, not a source of authority.
- `MusicLibrarySearchRequest` has no offset, so the library is a single page.
- Artwork is referenced by URL and never copied into our own storage.

Four MusicKit affordances are **deliberately never used**, and each would breach something above if it were:

- **Personalized recommendations.** Built from listening history, so unvetted by definition. No request for them is ever issued.
- **Autoplay past the end of a queue.** The one path that reaches unvetted material without anyone choosing it.
- **Radio and stations**, at least in v1, for the same reason: their contents cannot be judged ahead of playing them.
- **The user's own library as a browsing source.** It is a seeding input only; nothing the kid sees is read from it.

### Failure & concurrency semantics
**Errors are translated, not passed through.** A raw MusicKit error shown to a parent is a support ticket; a named `CatalogError` case is a sentence we can write. A `URLError` for a lost connection becomes `.offline`; anything else becomes `.underlying` with the message preserved.

**Failures that are not our bug but will be reported as ours.**

- `.restrictedOutsideApp` — Screen Time's music restriction, or Apple Music's own parental controls, refusing playback beneath us. The parent set this somewhere else, possibly months ago, and our app is where it surfaces. It needs detecting and explaining, with a pointer at the setting.
- `.cloudLibraryDisabled` — library reads return nothing. Distinct from an empty library, and the fix is in Settings. An empty list here reads as "you own no music".
- `.offline` — there is no download story under the MusicKit terms, so offline means the app does not work rather than degrading. Say so.

**Partial data.**

- `hasMore` is **inferred** from getting back a full page, because MusicKit gives no total count. The inference deliberately errs toward overshooting by one empty request rather than stopping early and claiming a search found nothing.
- A page returning fewer items than asked for ends the loop as `reachedEnd`, even if the source could theoretically have had more.
- An allow list entry whose item has vanished from the catalog resolves to `nil` rather than throwing. The admin shows it as unavailable rather than dropping it — an entry disappearing on its own would look like the app editing the parent's list.

**Retry.** The loop retries only to fill a page, never to recover from an error: a thrown error propagates immediately and aborts the search. The cap exists so a term with no clean results anywhere returns an honest empty state instead of paging forever.

**Concurrency.** `FilteredCatalog` and the sources are immutable values. The cache is an actor, so concurrent lookups serialise on it without a lock. Two searches in flight share the cache but not their loop state. Results are provisional in exactly one way: a verdict computed before ancestry resolution is not final, which is why the player re-checks immediately before playback.

### Data dependencies
Everything this layer reads comes from Apple, in a strict order, with real windows between the steps.

**Authorization** — `MusicAuthorization.request()`, a system prompt, once. Until it returns `.authorized` every catalog read fails. It can also be revoked later in Settings, mid-session, so authorization is not a launch-time fact that stays true.

**Subscription state** — `MusicSubscription.current`, then `subscriptionUpdates` for the life of the session. Requires authorization first. A plan lapsing mid-session is a real case, which is why this is an observed stream rather than a single read.

**Catalog reads** — search, lookup, children. Require authorization; playback additionally requires an active subscription. A search result carries the item's own rating.

**Ancestry** — a second, separate request. MusicKit returns no relationships with search results, so between a page arriving and its lineage resolving there is a window where items are only partly known. Nothing is judged in that window.

**Library reads** — require authorization _and_ `hasCloudLibraryEnabled`. When that flag is false the reads succeed and return nothing, which is why it is read explicitly rather than inferred from an empty result.

**Library-to-catalog matching** — depends on ISRC and UPC actually being populated on library items. How often they are is unmeasured, and it is the input this layer is least sure of. A low hit rate does not fail loudly; it silently discards more. That makes it something to measure rather than trust.

### Migration & existing data
**Nothing to migrate.** Nothing persists from this layer. The cache is in-memory and deliberately forgets everything on launch, which sidesteps the unanswered question of what the MusicKit terms let us store while still killing the repeat lookups that make a filtered page crawl.

One migration was considered and then **avoided by design**, and the reasoning is worth recording because it will not be obvious later.

When the library first came into scope, the plan was for a scope discriminator to travel with every identifier, and for `PolicyEntry` to gain a scope field — catalog and library identifiers being different namespaces. That would have meant every stored list entry carrying a discriminator, and a schema migration the moment the rule changed.

Resolving library picks to catalog items instead removed the axis entirely: one namespace, no scope field, no migration ever required. It also closed a correctness hole rather than merely a schema one — a deny on an artist could never have reached library-identified tracks, because there would have been nothing to match on.

If a future change reintroduces library-only identifiers, it reintroduces both the migration and that hole.

### Staged plan
**Stage 1 — the seam and the loop.** _Done._

- Ships: `CatalogSource`, `FilteredCatalog` with over-fetch and caps, `CachingCatalogSource`, `InMemoryItemCache`, `LibrarySource`, and MusicKit adapters compiling against the real SDK.
- Does not: run against a real account. The adapters are unverified beyond compiling.
- Exit test: 31 tests green in-process against stubs, with no network, no subscription and no device.

**Stage 2 — first contact with a real account.**

- Ships: the adapters exercised on a device with a signed-in Apple Music account, and the two standing inferences settled — whether `hasMore` behaves as assumed, and whether ISRC and UPC are populated often enough for seeding to be worth offering.
- Does not: tune anything. This stage measures.
- Exit test: a search returns filtered results on device; a library seed of at least fifty items reports its resolved and discarded counts — measured on a pre-26.4 system too, where `.findEquivalents` is not there to flatter the number.

**Stage 3 — tuning from the measurements.**

- Ships: `overFetchMultiplier` and `maxRetries` set from observed explicit and unrated frequencies rather than guessed.
- Does not: add persistence to the cache. That still waits on an answer about what the terms permit.
- Exit test: a typical kid's search fills a page in one request more often than not, with `requestCount` recorded across a spread of real terms.

**Stage 4 — persistence, only if measurement demands it.**

- Ships: an on-disk cache behind the existing `ItemCache` protocol, if session-only proves too slow.
- Does not: ship without a written answer on what metadata may be stored and for how long.
- Exit test: the admin's allow list renders with no network round trip per row.

## Review
_Not reviewed._

## Open notes
_None._
