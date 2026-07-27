# Open Questions and Research Tasks

**Status:** active

## Body
Ordered by how much the answer would change the plan. The first group should be settled before writing much code — a bad answer to any of them means a different app.

## Could change or kill the whole thing

### 1. Can we charge for this?

The license says we may not "indirectly monetize access to the Apple Music service." A paid app whose entire value is controlled access to Apple Music sits uncomfortably close to that line. Read the current agreement text directly, then look at how shipped apps handle it — there are third-party Apple Music clients on the store, some paid, so precedent exists. If it's genuinely ambiguous, ask Apple in writing before building a business on it.

**Good answer looks like: **a named shipped app with a comparable model, or a written reply from Apple.

### 2. Will App Review approve an app that deliberately restricts the catalog?

The terms say "full songs must be enabled for playback" and that users must be able to initiate and control playback. We comply on both counts for anything we allow — but we're also hiding large parts of the catalog on purpose. Is that a violation or is it fine? Parental-control apps clearly exist, so probably fine, but MusicKit-based ones that filter the catalog are rarer. Worth finding one.

### 3. How often is contentRating nil?

This is the cheapest high-value experiment we can run and it decides the shape of level 2. Write a throwaway app, search 50 varied terms, and count how many songs and albums come back with `nil` ratings versus `.clean` versus `.explicit`. Break it down by genre and by release era — older catalog and international catalog are the likely gaps.

- If nil is rare, treat nil as blocked and move on.
- If nil is common, blocking it makes the app feel broken, and allowing it makes the filter meaningless. We'd need a third path — a "needs review" bucket that surfaces to the parent, or a fallback signal like the album's rating standing in for an unrated track.

### 4. Does Apple already filter explicit content for us when the account is restricted?

Set Screen Time to Clean on a test device, then run the same search with and without it. If Apple filters explicit items out of the _results_ (not just blocks playback), level 2 gets much easier and much more reliable. If it only blocks playback, we're doing all the work ourselves. Test on both iOS and Mac, and with the Apple Music web Parental Controls toggle too, since they appear to be separate systems.

### 5. Does any of this actually work on a real child account?

Set up a genuine Family Sharing child account under 13 with an Apple Music Family plan and run the whole flow: authorization prompt, subscription check, search, playback. Child accounts have quirks — they can't have an Apple Music profile, for instance — and there may be more we don't know about. Do not assume a normal adult test account tells us anything about this.

---

## Shapes the design but won't kill it

### 6. Is filtered search still usable?

Since we filter client-side, a page of 25 results might become 12. Measure it across realistic kid searches. Figure out the over-fetch multiplier we need so a page feels full, and where that starts costing too much latency or too many requests.

### 7. What does "allow this artist" actually mean?

A parent taps allow on an artist. That has to become a set of playable things, and it has to stay correct when the artist releases a new album next month — possibly an explicit one. Resolve at play time against the live catalog, or snapshot at approval time? Snapshot is predictable but goes stale. Live is fresh but means a parent's approval silently expands. Probably: live resolution, with the level 2 explicit filter still applied on top even inside an allowed artist, plus a note to the parent when new material appears.

### 8. How do we handle playlists at all?

Playlists have no content rating, and Apple-curated playlists change without notice. Screening every track at approval time is a snapshot that goes stale within days. Options: screen at play time track by track, skipping blocked entries; only allow playlists the parent built themselves; or allow Apple playlists but filter live. Needs a decision.

### 9. Do we need Family Controls, or is a passcode enough?

A passcode on the admin screen is table stakes and needs no entitlement. Shielding the real Music app and Safari needs Family Controls, which means an approval request and weeks of lead time, iOS only. Decide whether v1 ships without it and tells parents to use Guided Access, or whether the entitlement is core enough to request now. If it's core, request it now regardless — the request is free and the waiting is the expensive part.

### 10. How does the allowlist get from the parent's phone to the kid's iPad?

Different Apple Accounts means iCloud private sync won't do it. Real options: CloudKit with CKShare (needs a custom record zone, and the SwiftData story here is reportedly rough), a small server of our own, or sidestep it entirely for v1 by requiring the parent to configure the kid's device directly. Prototype the CloudKit sharing path before committing — it's the kind of thing that looks fine in the docs and eats two weeks.

### 11. Kids Category or plain 4+?

Kids Category gets discovery and parental trust, but the rules are sticky and permanent, and they constrain analytics. Since the paying customer is the parent, a 4+ rating outside the category may serve us better. Look at what comparable kid-music apps chose.

### 12. What are we legally allowed to log about a child?

The reporting feature is the whole point of level 3, and it means recording a child's search queries. That's squarely in COPPA territory in the US, plus a growing pile of state laws and the UK Age Appropriate Design Code if we ship internationally. Get real answers on: what we can store, where it can live, how long we can keep it, whether the child needs to be told, and what "parental consent" has to look like. Keeping everything on-device or in the family's own iCloud, with nothing on our servers, sidesteps most of it — which is a good argument for that architecture beyond mere simplicity.

---

## Worth knowing eventually

- **Autoplay and radio.** When a queue ends, MusicKit can keep going into personalized territory we never vetted. Confirm we can turn that off completely, and check whether station and radio playback can be disabled too.
- **Personalized recommendations.** Any "made for you" surface is built from history and is unvetted by definition. Probably we just don't use them, but confirm nothing sneaks in through the player.
- **Lyrics.** MusicKit doesn't expose lyric text, so we can't screen on it or show it. Confirm, and note it as a limitation — a clean-rated song with rough lyrics is exactly the gap parents will find.
- **Search-as-you-type cost.** Find the actual rate limits for catalog search and decide on debouncing.
- **Voice search.** Pre-readers can't type. Speech recognition into a search term, with the transcript logged for the parent's report.
- **Offline.** The license forbids downloading, so there's no offline story through MusicKit. Confirm and set expectations — parents will ask about car trips.
- **Caching rules.** We need to store artist and album IDs and names to make allowlists work. Confirm what metadata we may persist and for how long, since the terms restrict metadata use.
- **Fallbacks if MusicKit doesn't work out.** Spotify's iOS SDK needs Premium and remote-controls the Spotify app rather than playing in ours, which breaks the sandbox. YouTube Music has no SDK. A "bring your own audio files" mode is a much smaller product but has none of the licensing questions.

## References
_None._

## Child pages
_None._
