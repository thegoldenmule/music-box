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

**Answered on device, July 2026: nil is not merely rare, it did not appear at all.** Across repeated song searches on a US storefront every result carried a rating, and the unrated count read zero every time. So `UnratedBehavior.block` costs nothing as a default, and the third path contemplated below — a "needs review" bucket, or inheriting an album's rating — does not need building. It stays in the code as a configurable behaviour because the cost of keeping it is one enum, and the cost of having removed it would be a schema change.

It also reflects on question 6: if unrated never appears, the filter's holes come from explicit content alone, which makes an over-fetch multiplier of 3 look generous rather than thin.

**Scope, before treating this as closed.** Songs only, one storefront, one adult account. Albums were not searched, and albums carry their own `contentRating`. The two hypothesised gaps above — older catalogue and international catalogue — were not probed at all, which is precisely what `Tools/RatingProbe` was for; the measurement here was a diagnostic row in the debug app, not a survey. The default is safe either way: if `nil` does turn up in some corner of the catalogue, blocking it is the conservative failure rather than the dangerous one.

### 4. Does Apple already filter explicit content for us when the account is restricted?

Set Screen Time to Clean on a test device, then run the same search with and without it. If Apple filters explicit items out of the _results_ (not just blocks playback), level 2 gets much easier and much more reliable. If it only blocks playback, we're doing all the work ourselves. Test on both iOS and Mac, and with the Apple Music web Parental Controls toggle too, since they appear to be separate systems.

### 5. Does any of this actually work on a real child account?

Set up a genuine Family Sharing child account under 13 with an Apple Music Family plan and run the whole flow: authorization prompt, subscription check, search, playback. Child accounts have quirks — they can't have an Apple Music profile, for instance — and there may be more we don't know about. Do not assume a normal adult test account tells us anything about this.

---

## Shapes the design but won't kill it

### 6. Is filtered search still usable?

Since we filter client-side, a page of 25 results might become 12. Measure it across realistic kid searches. Figure out the over-fetch multiplier we need so a page feels full, and where that starts costing too much latency or too many requests.

**Partly answered by the first device run, and the constraint is tighter than assumed:** Apple Music caps search `limit` at 25. An over-fetch multiplier has no room at all once the caller wants a page of 25, so compensating for filtering holes means more requests at increasing offsets rather than one bigger request. That turns this into a latency and request-count question, not a page-size one.

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

### 13. Does ancestry actually resolve on real search results? — _answered: yes_

MusicKit returns no relationships with search results, so every result's album and artist are fetched in a batch before anything is judged. On the first device run MusicKit logged empty identifier sets for album relationships. Empties are now dropped rather than stored — but that log cannot distinguish harmless noise from lineage never arriving, and the difference is not cosmetic: **if ancestry does not resolve, a deny on an artist reaches nothing**, and a core feature silently does nothing while appearing to work. Measure it by comparing the count of judged items carrying a non-empty artist ancestor against the total judged; the debug slice shows both. Then confirm behaviourally — deny an artist, search again, and check that every other track by them moves to blocked with that artist named as the cause.

**Answered on device, July 2026, and the answer is the good one.** Every judged item in a song search carried a non-empty artist ancestor — the count matched the total judged exactly — and denying an artist from a result moved every other track by that artist into the blocked list, naming the artist as the cause. So ancestry resolves, and artist-level denies genuinely reach an artist's catalogue. The empty identifier sets MusicKit logs so freely are noise, not lineage failing to arrive.

Two things stop this being fully closed. It was measured on song searches, from one storefront, on one adult account — the real under-13 account may differ, and that is question 5. And _album_ ancestry was not separately confirmed; only the artist count was read. An album deny is the weaker of the two anyway, since a deny on the artist subsumes it, but the count is on screen and worth a glance next time.

### 14. What error does MusicKit throw when something outside the app refuses playback?

Screen Time's music restriction and Apple Music's own parental controls both refuse playback, and a refusal from either must be logged as `restrictedOutsideApp` rather than attributed to a parent's own rule — otherwise a parent reads their own list as having blocked something they never denied. Which error MusicKit actually throws is unknown, so those refusals currently fall through to a generic underlying error: wrong, but not a confident lie about which rule fired. Reproduce by setting Screen Time to Clean, playing an explicit track, and recording the exact error type, domain and code on both iOS and Mac. Closely related to question 4, and cheap to answer at the same time.

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

## Sync probes: one answered, one half answered, one still open

**Two corrections to what this section used to say. **The iCloud capability is enabled on the App ID and the container iCloud.com.thegoldenmule.auralsanbox exists and is assigned, confirmed by reading the local provisioning profiles: both carry the container along with icloud-services and both container environments. And the simulator does not answer none of them. It answered Probe C outright and the owner half of Probe A, against the real production container. What it cannot answer is anything needing a second Apple Account or a real under-13 account, which is the rest.

1. **Probe A, can a share participant write? HALF ANSWERED, and the half that decides the architecture is the half still open. **Owner side: a zone-wide CKShare(recordZoneID:) was created and saved against the real container, from a simulator, on 2026-08-02. So creating one is not refused and the topology is not dead on arrival. Participant side is untouched: whether a second Apple Account can WRITE to that shared zone is the reported failure mode and the design's kill condition, and it cannot come from one machine. It needs two devices and two accounts, and nothing short of that answers it.
2. **Probe B, can an under-13 Apple Account accept a share? STILL OPEN. **Not attempted and not attemptable here: an under-13 account cannot be signed into a simulator in any way that means anything, and Screen Time, which is what produces CKAccountStatus.restricted, cannot be tested there at all. This still decides whether kid profiles can be tied to Apple IDs or whether every kid device runs under a parent's account and the device binding is the only key.
3. **Probe C, does CKRecord.encryptedValues carry Data? ANSWERED: YES. **64 bytes round-tripped against the real container, along with a String, and clear values on the same record were unaffected. So the activity segment payload and the passcode verifier can both be encrypted, and the reworded COPPA position rests on something measured rather than assumed. This was the cheapest of the three and the one gating the encryption disposition table.

**Answered by desk research, and worth recording as answered: **SwiftData's CloudKitDatabase has exactly automatic, private(_:) and none. There is no shared-database store scope, so a second parent's device could never read a share through SwiftData mirroring regardless of what the owner side can do. That closes the participant half of the zoneNote question in FamilyStore.swift and is why the sync design does not mirror the store at all.

**How the answered ones were run, so they are repeatable: **the app carries a throwaway probe screen behind the admin gate plus a -runCloudKitProbe YES launch argument, so the result is captured rather than tapped through. simctl launch --console-pty is what carries print() out of a simulator; plain --console produced nothing at all. Both the screen and the flag are meant to be deleted once these answers are written down, which is what this section is.

## Verified while wiring the iCloud entitlement

**ModelConfiguration's cloudKitDatabase defaults to .automatic, and .automatic does not mean off. It means on if the app is entitled.** This matters more than it sounds. The entire sync design rests on the SwiftData store never being mirrored, and that premise was being held up by an accident of provisioning rather than by anything in the code: the store had no CloudKit container attached only because the app carried no iCloud entitlement. Adding one flipped SwiftData into CloudKit mode by itself.

It failed loudly rather than quietly, which is the one mercy. The store stopped opening at all, with NSCocoaErrorDomain 134060: CloudKit integration requires that all relationships be optional, the following are not, listing sixteen of them. FamilyStore.container() now passes cloudKitDatabase: .none explicitly, with the reasoning beside it.

**The second half of that error is a fact worth keeping on its own:** CloudKit requires to-many relationships to be optional, not only their inverses. The inverses are the half already done, and the half CLAUDE.md and the Storage spec both describe as finished. Sixteen to-many arrays are not optional. Nothing wants mirroring, so this is deliberately left alone rather than paid for, but it is a schema change and therefore cheap now and a migration later. Anyone reconsidering mirroring should read that as the price of entry.

**Two smaller corrections from the same session.** On macOS the push entitlement is com.apple.developer.aps-environment; the unprefixed aps-environment is iOS-only and inert there, and getting it wrong is not a build failure but a Mac that silently never receives a CloudKit change notification. And xcodebuild can register a device after all, with -allowProvisioningDeviceRegistration alongside -allowProvisioningUpdates, so the claim that it cannot is wrong wherever it appears.

**One thing Probe A does not need to establish, because Apple documents it. **A participant holding readWrite can write to a share: the sample in Sharing CloudKit Data with Other iCloud Users has device B editing a shared record and the change landing in device A's private database. What that sample demonstrates is hierarchy sharing — a root record with children pulled in by parent references — so it says nothing about CKShare(recordZoneID:), which is what this design uses and what the probe is actually for. Also documented, and worth stating because the shorthand runs the other way: Apple Family Sharing grants no CloudKit access whatsoever. Every participant is invited explicitly and must accept. See the Accounts, Devices and Sync spec for what that does to the invite flow and to the supposed fallback.

## Measured: the sync engine, end to end against the real container

**Records reach CloudKit. **A throwaway probe seeded a household — one child, one deny, one playlist with a song — started CKSyncEngine against the real private database from a simulator, and pushed. Result: the store opened with mirroring off, both engines constructed, the engine reported a successful send, all three zones appeared on the server (household, kid-<uuid>-policy, kid-<uuid>-work), and the outbox drained to zero. That is the first end-to-end evidence in this effort; everything before it proved only that the pieces agreed with each other.

**It found a bug on the first run, and the bug is the interesting part. **The outbox drained to one of five rather than zero. The engine placed each record by asking which kid it belonged to, with the rule kidID ?? id — right for Kid, whose own identifier is the kid, and silently wrong for PlaylistEntryRecord and SuggestionEntryRecord, which carry playlistID and suggestionID and no kidID at all. Those were placed in kid-<their own id>-work, a zone that does not exist, so they could never be sent. Nothing errored. The only symptom was a number that did not reach zero.

Two fixes: the entry records now carry the owning kid on the wire, and the placement rule is explicit per type rather than a fallback. A test now builds one of every encodable record and asserts each lands in a zone the household actually owns. That check would have caught it; no test written before it could, because every one of them compared our own code against itself.

**Two smaller notes for whoever runs this next. **Querying a zone by recordName fails with CKError 12, Field recordName is not marked queryable — that is a schema-index thing and a limitation of verifying by query, not a sync failure; the zones and the drained outbox are the evidence. And each probe run leaves its zones behind under a fresh kid UUID, so the container accumulates litter that wants clearing out of the development environment.

## Measured: the owner-side sharing read path, 11 Aug 2026

**Method.** A throwaway probe in the app target behind a `-probeSharing` launch argument, run on a booted iPhone 17 Pro simulator (iOS 26.2) with a real Apple Account signed in, against the real container `iCloud.com.thegoldenmule.auralsanbox`. A debug build uses the _development_ CloudKit database, so none of this touches production. Invoked with `simctl launch --console-pty` — plain `--console` swallows `print()`. The probe calls `exit(0)` when done, without which the run never returns and the output never flushes, because a SwiftUI app does not terminate.

**What it was for.** `CloudKitSharing.existingShare(for:)` was introduced so that reading a roster stops creating one, and every read in the type now goes through it — `participants`, `reconcileGrants`, `removeParticipant`. A miss there is invisible: an empty roster and a reconciliation that does nothing are indistinguishable from "nobody has joined yet", which is also the expected state. No test can reach it, because no test carries an entitlement.

**Pointed at the **`child`** role on a fake kid UUID**, deliberately. That role's anchor is `kid-<uuid>-work`, so the whole run happens in zones named after a child who does not exist and no `CKShare` goes onto the real `household` zone as a side effect of a diagnostic. The two zones were deleted at the end; the empty `household` zone was left, since `SyncEngineHost.start` creates it on every launch anyway.

| Asked | Expected | Got |
| :--- | :--- | :--- |
| `side()` on a device that has accepted nothing | owner | owner |
| `participants()` before any invitation exists | 0, and no household share created | 0, household share absent |
| `invitation(for: .child)` | a URL | `www.icloud.com`, 3 path components |
| share on `kid-<uuid>-work` | present | present |
| share on `kid-<uuid>-policy` | present | present |
| share on `household` after a child invitation | absent — a child is never given the household | absent |
| a second identical `invitation(for: .child)` | same URL — found, not re-created | same URL |
| `reconcileGrants(.coParent)` with no co-parent invitation | 0 changes, and no household share created | 0, household share still absent |
| `reconcileGrants(.child)` with no participants | 0 changes | 0 |

**What this settles.** Three things, and each was previously reasoning rather than evidence. The read path finds a share that exists — the identical URL from a second invitation is the observable form of it, since a miss would have minted a second share with a new token. The read path also returns nothing for a zone that has no share, so `reconcileGrants` can now run on every launch and every foreground without publishing a household nobody invited into, which is the precondition automatic sync was waiting on. And `SharePlan`'s grant matrix lands where it says: a child invitation put shares on exactly their two zones and not on the household.

**What it does not settle, and the list is unchanged.** This is the owner half. **Probe A's participant-write question is untouched** — whether a second Apple Account can write to a zone-wide shared zone is still this design's kill condition, and a simulator has one account, so nothing short of two devices answers it. Also still open: whether `application(_:userDidAcceptCloudKitShareWith:)` is delivered to a SwiftUI app's `UIApplicationDelegateAdaptor` rather than swallowed by SwiftUI's own scene delegate, which needs a real share URL and therefore a second account; and whether `shareParticipants(forUserRecordIDs:)` resolves an account known only from a share. Probe B is untouched.

**Two mechanical notes worth keeping, both of which cost time.** The app's bundle identifier is `com.thegoldenmule.auralsanbox` — it carries the same missing `d` as the CloudKit container, and `simctl launch` fails with `FBSOpenApplicationServiceErrorDomain code=4` for the spelling anyone would guess. And a simulator with no iCloud account reports `CKAccountStatus.temporarilyUnavailable` (raw value 4), not `noAccount` — so the status alone does not distinguish "nobody signed in" from "ask again later". `MobileMeAccounts.plist` under the device's `data/Library/Preferences` is the reliable tell, and it is written lazily, so its absence on a booted simulator proves nothing either.

**Decided, 11 Aug 2026 — a weekly summary keeps raw search terms.** Maintainer's call, and it settles the half of research question 6 that gates the summariser: counts and top-N are not enough, the terms themselves survive compaction. The consequence to hold onto is that the summary inherits the sensitivity of the events it replaces, so aging events out stops being a privacy improvement and is only a storage one — the COPPA argument for a short window is weaker than it looked. The window itself is still undecided and nothing sweeps.

**Decided, 11 Aug 2026 — the retention window is 90 days, and parents can delete whenever.** Maintainer's call, closing the rest of research question 6. Events older than 90 whole days roll into a `WeeklySummaryRecord` and are deleted; `Kid.deleteHistory` is unbounded, immediate and unrelated to the window. Built in `RetentionSweep`, with three clamps that each prevent a different silent loss: only rows carrying `exportedAt` are swept, the boundary is pulled back to `RecentsProjector.retentionFloor`, and only whole weeks are eligible. The owner-and-lease the plan called for was replaced with an idempotence story — a deterministic payload under a `(kid, weekStart)` natural key — which the spec's own wording allows as the alternative.

## References
_None._

## Child pages
_None._
