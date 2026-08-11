# What We Know About MusicKit

**Status:** active

## Body
Verified against Apple's docs and license terms as of July 2026. These are the facts that shape the design. Anything still unknown lives in Open Questions and Research Tasks.

## The basics work in our favor

- `ApplicationMusicPlayer` streams the full Apple Music catalog _inside our app_, with its own queue, separate from the Music app's state. It also keeps playing in the background if we set the audio background mode. This is exactly the primitive we need.
- Native apps don't need a server or a developer token. Enable the MusicKit capability on the App ID and MusicKit handles tokens automatically. A first version can be entirely client-side.
- Authorization is a normal permission prompt via `MusicAuthorization.request()`.
- Playback needs an active Apple Music subscription on the signed-in account. Check `MusicSubscription.current.canPlayCatalogContent` before promising anything, and `canBecomeSubscriber` if we want to offer a signup.
- Under Family Sharing, each kid can have their own Apple Account (yes, under 13) with their own library, history, and recommendations, all covered by one Apple Music Family plan. That means a kid's listening doesn't pollute the parent's recommendations — important, and it's the setup we should assume.

## Platform floors

| Thing | iOS | macOS |
| --- | --- | --- |
| MusicKit, `MusicSubscription`, `contentRating` | 15.0+ | 12.0+ |
| `ApplicationMusicPlayer` | 15.0+ | **14.0+** |
| Family Controls / Screen Time API | 15.0+ | Catalyst only, no native Mac |

The macOS 14 floor on the player is the notable one. Sonoma or newer for the Mac app, no way around it if we want in-app playback.

## Explicit detection is thinner than you'd hope

This is the single most important finding for level 2, and it's worse than expected.

- `ContentRating` has exactly two cases: `.clean` and `.explicit`. The property is optional, and `nil` means "no rating available" — not "safe." So "non-explicit" is a three-state problem, not a boolean, and we have to decide what to do with unrated tracks.
- Song and Album both have `contentRating`. **Playlist does not.** A playlist has to be judged track by track, and its tracks can change under us at any time.
- **Search has no content filter at all.** `MusicCatalogSearchRequest` exposes only `term`, `types`, `limit`, `offset`, and `includeTopResults`. Every bit of filtering is ours, client-side, after the results come back. That means holes in result pages and over-fetching to compensate.
- A rating tells you about lyrics, not about themes. A clean-rated song can still be about something a parent wouldn't pick. Level 2 is a filter, not a guarantee, and we should describe it that way.

## Screen Time interacts with playback, unpredictably

Two separate systems can block explicit playback underneath us: the device's Screen Time content restriction (Music, Podcasts & News set to "Clean") and Apple Music's own Parental Controls in account settings. When either is on, third-party MusicKit playback of an explicit track fails.

- MusicKit JS developers report a hard `CONTENT_RESTRICTED` error. Apple couldn't reproduce it on a filed Feedback (FB12353357) and it's still open.
- On Mac, tracks with `contentRating == .explicit` have been reported to fail with "Failed to prepare to play" (`MPMusicPlayerControllerErrorDomain` 6) while the same tracks play on iOS.

Read both ways: it's a useful second layer of defense we get for free, and it's a source of confusing failures we'll have to handle gracefully. Either way we cannot rely on it — our own filtering has to be the real gate. It also means we need clear error handling for "blocked by something outside this app," or parents will report it as our bug.

## License terms that constrain the product

From the Apple Developer Program License Agreement, section 3.3.6(D), plus the MusicKit terms. Paraphrased — read the current agreement directly before making business decisions on these.

- Full songs must be enabled for playback. No clipping or previewing as a safety mechanism.
- The user must initiate playback and have standard controls: play, pause, skip.
- Content plays only as rendered by the MusicKit APIs. No downloading, uploading, or modifying.
- Artwork and music text can only appear alongside playback or playlist management, not on their own.
- User metadata such as playlists and favorites may only be used for a clearly disclosed purpose directly relevant to the app.
- **You may not require payment for, or indirectly monetize access to, the Apple Music service, including through in-app purchase, advertising, or requesting user info.**

That last one needs a real answer before we pick a business model. A paid parental-control app that only works with the user's own Apple Music subscription is probably fine, but "probably" isn't good enough to build on.

## Kids Category rules, if we go there

- Pick one age band: 5 and under, 6 to 8, or 9 to 11.
- No third-party analytics. No third-party ads.
- No personally identifiable info or device info to third parties, including from the adult section, without explicit parental consent.
- Parental gates required before in-app purchase or any link out of the app. For pre-readers, gates need voiceover prompts.
- The rules are sticky. Once customers expect Kids Category behavior, later updates must keep meeting it even if we deselect the category.

Worth noting: this app is arguably for the parent, used by the kid. We may be better off rated 4+ outside the Kids Category, which keeps the analytics and gating rules from binding us. That's a decision, not a given.

## Family Controls needs Apple's permission, and lead time

- Entitlement is `com.apple.developer.family-controls`. Development works immediately; shipping to TestFlight or the App Store does not.
- Distribution requires a separate manual request to Apple, per bundle ID, plus one for every Screen Time extension we ship.
- Reported turnaround runs from a few business days to several weeks. If we want it, request early.
- Apple looks for a genuine parental-control use case and specifically checks you're not harvesting usage data for advertising or profiling. Our reporting feature needs to be framed carefully.
- Once authorized, the framework blocks the child from deleting the app or signing out of iCloud, which is the actual tamper resistance we'd be buying.

## Measured on a device, not read in a doc

Everything above this line is desk research. Everything in this section is something we had wrong until a real device said otherwise, on the first run against the real Apple Music API in July 2026. Each one cost a working build, and none of them could have been caught here: the test stubs serve whatever they are asked for, `swift build` targets macOS, and MusicKit in the simulator refuses playback outright with `MPMusicPlayerController is not available on the simulator`.

### Search caps `limit` at 25

Asking for more is a hard failure, not a clamped page:

```text
GET /v1/catalog/us/search?term=Punch&types=songs&limit=75&offset=0

400  code 40005  Invalid Parameter Value
"Value must be an integer less than or equal to 25, but was: 75"
source: .parameter("limit")
```

This breaks the over-fetch strategy as originally designed. The loop asked for the caller's limit times an over-fetch multiplier of 3, under a page ceiling of 100 — so a perfectly ordinary search for 25 songs asked for 75 and every single search failed.

- **Over-fetching has to happen by paging, not by asking for a bigger page.** Once the caller's limit reaches 25 the multiplier has no room left at all, and the only way to compensate for filtering holes is more requests at increasing offsets. The multiplier still earns its keep at smaller limits, where one request can cover the need.
- `hasMore` must be judged against the _clamped_ limit, not the asked-for one. Judged against the request, a full page of 25 reads as "fewer than the 75 I wanted, so the catalog is exhausted" and paging stops after one request — turning a loud 400 into a silent truncation that looks like a search legitimately finding little.
- The cap is specific to search. Other endpoints allow more.

### Relationship items can arrive with empty identifiers

Resolving ancestry on real search results logs this, freely and often:

```text
No catalogID, libraryID, or deviceLocalID was found from underlying
identifier set <MPIdentifierSet EMPTY>. A MusicIdentifierSet with empty
string, for type MusicItemTypeValue(type: Album, rawValue: "Album"), is
being used.
```

An album or artist reached through a song's relationship may have an empty identifier. Storing that as an ancestor is worse than storing nothing: it matches no real album, every affected song shares the one identifier, and — the dangerous part — the item then _looks_ like it has lineage. The provisional-verdict rule keys off ancestry being empty, so a bogus entry turns a guess into what reads as a resolved fact. Empty identifiers are dropped rather than stored.

Whether ancestry resolves _at all_ on real results is a separate question this log cannot answer — it does not distinguish harmless noise from lineage silently failing to arrive. See Open Questions and Research Tasks.

### The MusicKit capability cannot be verified from a build

MusicKit is an App Service on the App ID, not an entitlement. It never appears in the provisioning profile, so a cleanly signed build proves the bundle identifier matches and signing works, and says nothing whatsoever about whether MusicKit is enabled. The only proof is a catalog request that comes back — a well-formed API error counts, an authorization failure does not.

### The account-store entitlement error is noise

Every launch logs this, several times:

```text
<ICUserIdentityStoreACAccountBackend> Failed to initialize active account,
error=Error Domain=ICError Code=-7013 "Client is not entitled to access
account store"

[ICUserIdentityStore] Failed to fetch local store account with error:
Error Domain=ICError Code=-7013 ...
```

`ICUserIdentityStore` belongs to the private iTunesCloud framework, and the account store it wants needs `com.apple.accounts.appleaccount.fullaccess` — an entitlement only Apple's own apps hold. Every third-party MusicKit app logs this. It does not affect authorization, subscription state, search or playback: the session that produced these lines was searching and playing fine.

Written down only because it reads exactly like the entitlement problem that _would_ explain a broken MusicKit setup, and chasing it costs an afternoon. If subscription state, storefront or account identity ever look wrong, this is the first log to re-examine — but on its own it is not evidence of anything.

## Sources

- [MusicKit overview](https://developer.apple.com/musickit/)
- [ApplicationMusicPlayer](https://developer.apple.com/documentation/musickit/applicationmusicplayer) and [MusicSubscription](https://developer.apple.com/documentation/musickit/musicsubscription)
- [ContentRating](https://developer.apple.com/documentation/musickit/contentrating), [Song](https://developer.apple.com/documentation/musickit/song), [Album](https://developer.apple.com/documentation/musickit/album), [Playlist](https://developer.apple.com/documentation/musickit/playlist)
- [MusicCatalogSearchRequest](https://developer.apple.com/documentation/musickit/musiccatalogsearchrequest)
- [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/) (section 3.3.6(D))
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) and [The Kids Category](https://developer.apple.com/app-store/kids-apps/)
- [Family Controls](https://developer.apple.com/documentation/familycontrols) and [Configuring Family Controls](https://developer.apple.com/documentation/xcode/configuring-family-controls)
- [How Family Sharing works](https://support.apple.com/en-us/105062)
- [CONTENT_RESTRICTED forum thread](https://developer.apple.com/forums/thread/731897)

## What the licence says about artwork and content

Verbatim from the **Apple Developer Program License Agreement** §3.3.6(D) "MusicKit", English-UK edition, page 32, read 27 July 2026. Fetched as PDF from developer.apple.com and text-extracted rather than paraphrased, because the exact wording is what the argument turns on.

> You agree not to call the MusicKit APIs or use MusicKit JS (or otherwise attempt to gain information through the MusicKit APIs or MusicKit JS) for purposes unrelated to facilitating access to Your end users' Apple Music subscriptions. If You access the MusicKit APIs or MusicKit JS, then You must follow the Apple Music Identity Guidelines.
>
> If You choose to offer music playback through the MusicKit APIs or MusicKit JS, full songs must be enabled for playback, and users must initiate playback and be able to navigate playback using standard media controls, such as "play", "pause" and "skip", and You agree to not misrepresent the functionality of these controls;
>
> You may not, and You may not permit Your end users to, download, upload or modify any MusicKit Content and MusicKit Content cannot be synchronised with any other content, unless otherwise permitted by Apple in the Documentation;
>
> You may play MusicKit Content only as rendered by the MusicKit APIs or MusicKit JS and only as permitted in the Documentation (e.g. album art and music-related text from the MusicKit API may not be used separately from music playback or managing playlists);
>
> Metadata from users (such as playlists and favourites) may only be used to provide a service or function that is clearly disclosed to end users and that is directly relevant to the use of Your Application, website or web application, as determined at Apple's sole discretion

**The operative word is "modify", and nothing defines it.** No clause names overlays, cropping or masking. The exposure is that a play badge laid over artwork obscures part of it and a circular mask removes part of it, and both are arguable modifications of MusicKit Content. This is not settled either way, so the app draws its own line and stays on one side of it: _clipping yes, compositing never_. The shape of the frame is ours; what the frame contains is Apple's and nothing of ours is ever drawn on top of it.

**What follows for the kid player's tiles.** Every kind distinction is drawn outside the artwork: a card behind the tile for anything that opens, a caret at the trailing edge of the line naming the kind, a play glyph beside the title for songs, and the kind word in that line. The artwork carries none of it.

- **Artists are masked to a circle, everything else to a rounded rectangle.** A circle crops harder than a rounded rectangle, so it is further along the clipping line rather than across a new one, and it is what the Music app itself does for artists — the convention a kid will have met in every other music app. This and the corner radius are the only places the app interprets "modify" rather than simply avoiding it.
- **Nothing is ever composited onto artwork.** No play badge, no lock, no overlay of any kind. A badge on the artwork was the first treatment considered and was dropped for this reason; the play glyph lives beside the title instead.
- **Placeholder glyphs are ours, not Apple's**. They appear only when there is no artwork — common for artists — so nothing is ever drawn over a real image.
- **Artwork bytes are still never copied into our storage**, which the same clause forbids outright. Only the URL is stored.

**The Apple Music Identity Guidelines do not mention album artwork at all.** All 63 sections cover Apple's own badges, lockups, icons, Shazam assets and marketing copy. This is worth writing down because it looks relevant and is not: a search for Apple Music "badge" rules returns "never change the badge artwork in any way", which is about the _Listen on Apple Music_ button and says nothing about a play glyph on a tile. The two meanings of "badge" are easy to conflate and the guidelines are incorporated into the licence by reference, so the mistake looks well-sourced.

### Artwork is cached in memory only — and `AsyncImage` was not

The clause above forbids _downloading_ MusicKit Content, and the standing rule is that only the artwork URL is stored. **SwiftUI's AsyncImage breaks that rule by default.** It loads through `URLSession.shared`, which uses `URLCache.shared` — and that has a disk capacity as well as a memory one. Every cover a kid scrolled past was being written to disk by the URL loading system, with no code of ours asking for it.

This one is read from Apple's documented defaults, not measured on a device — it sits above the measured line for that reason. That `URLCache.shared` is disk-backed is not in doubt; the on-disk footprint in this app is unquantified, and a probe that reads the cache directory after a scroll would settle it.

What the app does instead: `ArtworkCache` holds decoded images in an `NSCache`, behind a session built from `URLSessionConfiguration.ephemeral` with `urlCache` set to nil — no HTTP cache at all, nothing on the filesystem, and eviction under memory pressure for free. **The same change fixed artwork intermittently never appearing**: `AsyncImage` keeps nothing between appearances, shows its placeholder for a failure as well as a load, and never asks twice, so one lost request among two dozen tiles left a permanent grey square.

### Indirect monetisation — verbatim text for open question 4

The clause behind research question 4, from the same section. It narrows the question without settling it: the prohibition attaches to monetising _access to the Apple Music service_, not to charging for an application generally.

> You agree not to require payment for or indirectly monetise access to the Apple Music service (e.g. in-app purchase, advertising, requesting user info) through Your use of the MusicKit APIs, MusicKit JS or otherwise in any way.

**Still unanswered, and still blocking business-model decisions.** Whether a paid app that charges for the sandbox rather than for Apple Music falls inside "otherwise in any way" is a question for a lawyer, not for reading. What has changed is that the wording is now in hand rather than being recalled second-hand.

## Reading the parent's own library: playlists and artists

Established July 2026, while building parent suggestions. Everything below **compiles against the real MusicKit SDK** on macOS — which is a stronger claim than "recalled from the documentation" and a weaker one than "seen working". The MusicKit capability is still not enabled on the App ID, so none of it has run against a real account.

- `MusicLibraryRequest<Playlist>` and `MusicLibraryRequest<Artist>` both exist and take `.limit`, alongside the `<Song>` and `<Album>` requests already in use. Library seeding was song-and-album only because those are the kinds with codes, not because the other requests were missing.
- `MusicLibraryRequest<Playlist>` accepts `filter(matching: \.id, equalTo: MusicItemID(...))`, which is how one playlist is refetched by identifier after crossing out of CatalogKit as a value.
- A library `Playlist` exposes `name`, `curatorName`, `artwork`, `kind` and `tracks`, and `.with([.tracks])` loads them the same way it does for a catalog playlist. `tracks` is a collection of `Track`, so music videos have to be filtered out — the same `compactMap` that `children(of:)` already does.
- `Playlist.kind` is `nil` for a playlist the account holder made themselves. Every case of `Playlist.Kind` names something Apple produced, `personalMix` included — that one is a mix Apple built _for_ them, which is not the same thing. **Unverified:** whether a nil kind really is the only marker of an own-made playlist. It decides only a label a parent reads, never what is resolved.
- **There is still no way to get a catalog identifier for a library item.** No documented property returns one, and for a playlist there is nothing to return — nobody published it. The `PlayParameters`-to-JSON trick that circulates is undocumented, its keys are version-dependent, and it is deliberately not used here.

That last point forces two things, and both turn out cheaper than the missing identifier suggests. **A playlist is snapshotted track by track** through the ISRC path that already existed, and stored under a local UUID — so the catalog playlist identifier is never needed, not even for one of Apple's. **An artist is derived rather than matched**: `resolveToCatalog` already requests `[.albums, .artists]`, so a resolved song arrives carrying its catalog artist, and naming a library artist means resolving a sample of their songs and reading it off the results. No new matching rule, and no new request shape.

`song.artists.first` is not good enough to derive from on its own. It is right most of the time and wrong in exactly the cases a family library is full of: a track with a guest credit names the guest, a soundtrack names whoever opened it, a ripped compilation names “Various Artists”. So it is a majority vote over roughly ten songs, dropping empty identifiers first, that **refuses rather than guesses** when nothing clears the bar. The asymmetry is worth stating: a suggested artist is an allowed artist, so a wrong answer here hands a child a catalogue nobody chose — where a refusal costs the parent one catalog search.

One side effect worth noticing: the suggest-a-playlist confirm screen shows the parent “34 of 39 songs matched” before they commit, which makes the ISRC hit rate on a real library something the app reports every time it is used rather than something a hand-run probe has to answer once. That is open research question 2, measured continuously, as soon as the capability is enabled.

## References
_None._

## Child pages
_None._
