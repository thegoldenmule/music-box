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

## References
_None._

## Child pages
_None._
