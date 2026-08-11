# Spec: The Kid's Library

**Status:** restated

## Sections
### Motivation
The kid needs to be able to manage their own library (given the constraints of the policy engine), regardless of whether or not they are using a shared account. We also want to make sure the data is as portable as possible, so that one day they can take the music with them when they grow up.

### Overview
A kid can **favorite** a song, an album or an artist, and can **build playlists** out of songs they are allowed to play.

### Disambiguation

The admin already reads a library: `LibrarySource`, the ISRC/UPC shortcut a parent uses to seed allow and deny lists from their own music. **That path is untouched and unrelated.** Nothing in this spec is called from the admin, and nothing in the admin is called from here.

### The store interface

We provide a simple store interface with multiple implementations for various scenarios.

- **CloudKit** — our own records in the existing named zone.
- **Apple Music** — the account's real library, through MusicKit.

`isSharedDevice`, in the admin, determines which if these is used.

- **On** — Read from and write to CloudKit only. This is so that the kid does not alter the adult's music library.
- **Off** — Read from both (resulting in union), write to both.

When both are live, a read is the union. CloudKit includes things Apple Music has no primitive for, and things that would not resolve.

**Drift between the two is not reconciled.** If an Apple Music write fails, the item still appears on the kid's shelf from CloudKit. Healing divergence is later work, to be done only if it turns out to matter.

### Data model & types
```swift
// MARK: - The seam

/// The kid's library, whatever is actually holding it. Callers never ask which
/// provider something lives in; they ask the merged store.
protocol LibraryProvider: Sendable {
    var id: LibraryProviderID { get }
    var capabilities: LibraryCapabilities { get }

    func favorites() async throws -> [FavoriteRow]
    func addFavorite(_ item: CatalogItem) async throws
    func removeFavorite(_ id: CatalogID) async throws

    func playlists() async throws -> [PlaylistRow]
    func createPlaylist(named: String, songs: [CatalogItem]) async throws -> PlaylistRow
    func addToPlaylist(_ handle: PlaylistHandle, song: CatalogItem) async throws
    func removeFromPlaylist(_ handle: PlaylistHandle, song: CatalogID) async throws
    func renamePlaylist(_ handle: PlaylistHandle, to name: String) async throws
    func deletePlaylist(_ handle: PlaylistHandle) async throws
}

enum LibraryProviderID: String, Sendable {
    case cloudKit      // ours; ALWAYS live
    case appleMusic    // live when isSharedDevice == false, which is the default
}

/// What a provider can actually do.
///
/// Absence is not failure — it is a provider sitting one operation out while
/// the others carry it. Two gaps are Apple's and permanent: an artist has no
/// "add to library" form, and MusicKit edits only playlists this app created.
struct LibraryCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let favoriteSongs        = LibraryCapabilities(rawValue: 1 << 0)
    static let favoriteAlbums       = LibraryCapabilities(rawValue: 1 << 1)
    static let favoriteArtists      = LibraryCapabilities(rawValue: 1 << 2)
    static let createPlaylists      = LibraryCapabilities(rawValue: 1 << 3)
    static let editOwnPlaylists     = LibraryCapabilities(rawValue: 1 << 4)
    static let editForeignPlaylists = LibraryCapabilities(rawValue: 1 << 5)
}

/// Names one playlist across providers. A playlist has no catalog identifier —
/// it does not exist until someone makes it — so it needs a handle.
struct PlaylistHandle: Hashable, Sendable {
    let local: UUID              // ours; stable, survives everything
    let appleLibraryID: String?  // nil = no Apple counterpart (yet, or ever)
}

// MARK: - CloudKit provider records

/// A song, album or artist this kid marked. NEVER a playlist: a playlist is not
/// favorited, it is owned.
@Model
final class FavoriteRecord {
    var id: UUID
    var modifiedAt: Date
    var kid: Kid?

    var catalogID: String        // always an Apple Music catalog identifier
    var itemKind: String         // "song" | "album" | "artist"

    var displayName: String      // copied at write time, never refreshed
    var artworkURL: URL?         // referenced; bytes never stored
    var favoritedAt: Date

    /// "kid"          — tapped in this app
    /// "appleLibrary" — found in the Apple Music library and adopted
    var origin: String
}

/// A playlist the kid owns. Order is the content.
@Model
final class PlaylistRecord {
    var id: UUID
    var modifiedAt: Date
    var kid: Kid?

    var name: String
    var createdAt: Date

    /// The Apple Music library playlist this is the same playlist as.
    ///   nil — no counterpart: never created there, or the provider was not live.
    var appleLibraryID: String?

    /// True ONLY when this app created the Apple counterpart.
    ///
    /// MusicKit refuses to edit a playlist the app did not create and exposes no
    /// way to ask whether it did. Recorded at creation because it is otherwise
    /// unrecoverable: a playlist read back later is indistinguishable from one
    /// Apple made.
    var appleIsOurs: Bool

    var origin: String           // "kid" | "appleLibrary"

    @Relationship(deleteRule: .cascade) var entries: [PlaylistEntryRecord]
}

@Model
final class PlaylistEntryRecord {
    var id: UUID
    var modifiedAt: Date
    var playlist: PlaylistRecord?

    var catalogID: String        // ALWAYS a song
    var displayName: String
    var artworkURL: URL?

    /// 0-based, contiguous after any edit. Gaps are not a supported state.
    var position: Int
    var addedAt: Date
}

// MARK: - Device settings

/// Device-local, deliberately NOT in the CloudKit zone: it describes a device
/// and the Apple Music library on it, not the family. A second device has its
/// own answer, and syncing this would hand it one that is false there.
struct DeviceLibraryState: Codable {
    /// Defaults FALSE — both providers live, which is the case most families
    /// are in and the one the feature is for.
    ///
    /// Onboarding asks before the Apple provider's first read, so this default
    /// governs only the path where that question was never answered.
    var isSharedDevice: Bool
}
```

### Algorithm
**Which providers are live.**

```text
liveProviders() -> [LibraryProvider]

1. if device.isSharedDevice -> [cloudKit]
2. -> [cloudKit, appleMusic]
```

**Favoriting.** One kid-facing verb; a different Apple primitive per kind.

```text
addFavorite(item)

1. if engine.evaluate(item) is .blocked -> refuse, log the block, return
2. cap := item.kind == .song  ? .favoriteSongs
        : item.kind == .album ? .favoriteAlbums
        :                       .favoriteArtists
3. for each provider p in liveProviders() where p.capabilities.contains(cap):
     p.addFavorite(item)
4. cloudKit is AWAITED and a failure is surfaced.
   appleMusic is fire-and-forget and a failure is dropped.
```

Inside the Apple provider the kind picks the primitive: a song or album is **added to the library**; an artist has no library form and takes a favorite alone, if the framework offers one at all.

**Creating a playlist.**

```text
createPlaylist(name, songs)

1. drop any song the engine blocks; if none survive, refuse
2. cloudKit.createPlaylist -> PlaylistRecord(local: UUID, appleIsOurs: false)   // AWAITED
3. if appleMusic live AND supports .createPlaylists:
     3.1 applePlaylist := MusicLibrary.createPlaylist(name:, items: songs)
     3.2 record.appleLibraryID := applePlaylist.id
     3.3 record.appleIsOurs := TRUE       // the only moment this is knowable
4. -> PlaylistHandle(local:, appleLibraryID:)
```

Step 3.3 is why the field exists. MusicKit will not edit a playlist the app did not create and will not say which those are, so a playlist read back later is indistinguishable from one Apple made.

**Editing a playlist.**

```text
addToPlaylist(handle, song) / removeFromPlaylist / renamePlaylist / deletePlaylist

1. if adding: refuse if the engine blocks the song
2. cloudKit: apply, renumber `position` contiguously        // AWAITED
3. if appleMusic live AND handle.appleLibraryID != nil AND record.appleIsOurs:
     apply the same edit there                              // fire-and-forget
   else: skip
```

A playlist with `appleIsOurs == false` still shows and still plays; our copy is edited and Apple's is not. That divergence is stated to the parent in the admin and never to the kid.

**Reading.**

```text
favorites() / playlists()

1. rows := [] ; for each provider p in liveProviders(): rows += try? p.rows()
     // a provider that throws contributes nothing to this pass and is not an error
2. for Apple rows: resolve to catalog identifiers (ISRC / UPC, batched).
     anything that will not resolve is DROPPED, not stored
3. adopt: any Apple row absent from CloudKit -> write a CloudKit record with
     origin: "appleLibrary"      // so it survives the provider going away
4. merged := union by CatalogID (playlists: by PlaylistHandle), most recent first
5. items := catalog.items(for: merged ids)      // batched, cached
6. keep only what the engine allows             // render-time filter
7. -> merged
```

Step 4 is a union. **CloudKit expands what Apple Music returned**; it never contradicts it, prunes it, or pushes back into it. An item present in CloudKit and absent from Apple Music simply appears — which is why a failed Apple write costs the kid nothing visible, and why no reconciliation pass is needed to make the shelf correct.

**Searching the library.**

```text
searchLibrary(term) -> [CatalogItem]

1. entries := favorites() + playlist entries      // already policy-filtered
2. -> entries whose displayName or subtitle matches, case/diacritic-insensitive
```

A local predicate over rows already in hand. `MusicLibrarySearchRequest` is deliberately **not** used: it searches the whole signed-in library rather than the kid's own records.

### Invariants & limits
- **This is the kid's library only.** Nothing here is reachable from the admin, and the admin's existing library seeding (`LibrarySource`, ISRC/UPC matching for allow and deny lists) is neither used by it nor changed by it.
- **Neither a favorite nor a playlist entry is a permission.** Nothing here creates a `PolicyEntry` or changes a verdict. The policy engine remains the single authority.
- **A kid may only favorite, or add to a playlist, what they may currently play.** Every write asks the engine first and refuses a blocked item.
- **Everything read back is filtered at render time, never stored pre-filtered.** A parent may deny tomorrow what the kid favorited today: the row survives, the tile does not.
- **Playlist entries are always songs.** Albums and artists can be favorited but never added to a playlist — what would play is ambiguous, and the player queues songs.
- `isSharedDevice`** is the only input to which providers are live.** False (the default): both. True: CloudKit alone. There is no other gate and no derived trust state.
- `isSharedDevice`** defaults to false, is device-local, and never syncs.** It describes a device and the library on it, not the family.
- **The Apple provider's first read is not issued until onboarding has asked.** The default decides what happens if that question is never answered; it must not decide what happens before it is put.
- **CloudKit is always live.** Every operation therefore has at least one provider, and the feature is complete with Apple Music absent.
- **Callers never name a provider.** Every surface talks to the merged store.
- **A capability a provider lacks is not an error.** It sits that operation out and the others carry it. Only a provider _failing_ something it claims to support is a failure.
- **A read is a union, and CloudKit only ever expands it.** No read prunes, contradicts, or writes back into another provider.
- **Drift between providers is not reconciled.** An item in CloudKit and not in Apple Music stays that way. A deliberate limit, not an oversight: the union makes it invisible where it matters, and healing it is later work if it proves to matter at all.
- **Absence from the Apple Music library never deletes a CloudKit row.**
- **The CloudKit write is awaited and surfaced; the Apple Music write is fire-and-forget.** A heart must not fill on a write that did not land, and a copy that did not reach Apple must never block the kid.
- **Every stored identifier is an Apple Music catalog identifier.** Items read from the Apple Music library are resolved by ISRC and UPC first; anything that will not resolve is dropped rather than stored under a library identifier.
- `appleIsOurs`** is written at creation and never inferred.** MusicKit edits only playlists the app created and exposes no way to ask.
- **An edit is never attempted on a playlist we did not create.**
- **Favorites and playlists are exempt from event retention.** Plays and searches are events and may roll into summaries; these are durable user data, deleted only by the kid or with the kid.
- **Nothing about provider availability is ever shown to a kid.** Capability gaps and provider failures are admin-facing.
- `MusicLibrarySearchRequest`** is not used** for the kid's library search.
- **Artwork bytes are never copied into our storage.** `artworkURL` is a reference; `displayName` is a copied string so a list renders offline.

### Failure & concurrency semantics
**No failure below can take the feature away.** CloudKit is always live, so favorites, playlists and search over them keep working through all of it. What degrades is only whether the kid's library is _also_ a real Apple Music library.

**A provider cannot do something.** Not a failure. The merged store skips it and the others proceed — an artist favorite Apple Music has no primitive for is still a favorite in our records, and the kid sees no difference.

**A provider fails an operation it claims to support.** CloudKit failing is surfaced: the write was the fact, and a filled heart over a failed write is a lie. Apple Music failing is dropped. The item lives in CloudKit, the union puts it on the shelf anyway, and the only cost is that it is not in the kid's Apple Music library. **There is no retry and no queue** — see the note on drift below.

**Apple Music unavailable.** No subscription, iCloud Music Library off, no network, authorization revoked mid-session: all the same shape. The provider throws or returns nothing, contributes nothing to that pass, and the CloudKit rows render alone. None of these is modelled as a distinct state, because none of them changes what the app should do.

**A library read fails.** Treated as an empty Apple library for that pass. No adoption, no deletion, and nothing pushed — there is nothing to push, because reads never write back into a provider.

**Resolution failure.** A library item whose ISRC or UPC finds no catalog match is dropped from that read and never stored. Not an error, not shown to the kid, counted in the admin — the rate is open research question 2 and this is the first feature that depends on it at runtime.

**Drift is a known, accepted, permanent-until-addressed condition.** Two libraries can disagree: a failed write, a device that was shared when the favorite was made, a song the kid removed in the Music app. None of it is repaired. The union means the kid's shelf is right regardless — CloudKit holds everything — so drift costs only the completeness of the Apple-side copy. If that turns out to matter, reconciliation is a later pass over the same seam and needs no schema change to add.

**Playlist divergence** is the one case where the two disagree about _content_ rather than completeness: a playlist with `appleIsOurs == false` accepts edits in our copy and silently not in Apple's. Permanent rather than transient, so the admin states it plainly.

**Offline.** No download story exists under the MusicKit terms, so offline means no playback regardless. The lists still render — `displayName` and `artworkURL` are copied at write time precisely so they can.

**Conflict and concurrency.** `FavoriteRecord` is keyed by `(kid, catalogID, itemKind)` and writes are upserts, so the same favorite arriving twice — tapped twice, or adopted while being tapped — collapses to one row. Playlist `position` is renumbered contiguously after every edit rather than left sparse, so two racing edits produce a consistent order rather than a gap. Under CloudKit sync in v2, two devices asserting the same favorite converge last-writer-wins on `modifiedAt`, correct for set membership. An unfavorite racing an adoption is the one real conflict: the unfavorite wins, being the only one of the two a person did deliberately.

**Provisional results.** A verdict on an item whose ancestry has not resolved is provisional, as everywhere: deny fails open, allow-only fails closed. The player re-checks immediately before playback regardless, which is what makes a playlist built weeks ago safe to press play on.

### Data dependencies
Four inputs. Two are local and immediate; two arrive after launch with a real window before they do.

**The policy engine** — in process, synchronous, no window. Rebuilt when the kid's policy changes. Consulted on every write and every read. Nothing here is judged by anything else.

**CloudKit provider rows** — local SwiftData, available on the first frame. This is why there is no meaningful loading state: names and artwork URLs were copied at write time, so the shelf draws before any network call resolves anything. `DeviceLibraryState` is read synchronously alongside them and never syncs.

**Authorization and subscription state** — `MusicAuthorization.request()` once, then `MusicSubscription.current` and `subscriptionUpdates` for the session. The Apple provider needs both, and authorization can be revoked in Settings mid-session. Neither is consulted to decide whether the provider is _live_ — `isSharedDevice` alone does that — but either can make it return nothing, which is handled as a provider contributing nothing rather than as a state.

**The Apple Music library** — `MusicLibraryRequest`, requiring authorization _and_ `hasCloudLibraryEnabled`. Its items arrive as library identifiers and are **not usable until resolved to catalog identifiers** by a second batched request on ISRC and UPC. Between those two steps items are only partly known, and nothing is written, judged or displayed in that window.

### The dependency this feature is least sure of

The library-to-catalog resolution rate. Open research question 2 asks whether ISRC and UPC are populated often enough for library seeding to be worth offering; until now a poor rate meant an optional admin shortcut discarded more. Here it means a kid's own library reads back incomplete — they added a song in the Music app and it is not here.

That failure is quiet and reads as a bug in us, which is why the admin counts discards. It is bounded, though: it affects only what the Apple provider contributes to a read. Nothing the kid does in this app depends on it, because everything the kid does lands in CloudKit first.

### A dependency that may not exist

Whether MusicKit Swift exposes favoriting at all, for any kind. Adding a song or album to the library is documented and certain; favoriting is not, and artists have no library form to fall back on. If it turns out to be Apple Music API only, the provider reaches it through `MusicDataRequest`, which carries the user token to arbitrary endpoints — the seam absorbs that and no caller learns of it. See Open questions this opens.

### Migration & existing data
**Nothing to migrate: none of this exists.** There is no favorites, likes, hearts or playlist concept anywhere in `FamilyStore`, `CatalogKit` or the app, and nothing in the wiki describes one. `FavoriteRecord`, `PlaylistRecord` and `PlaylistEntryRecord` are new models in the existing named custom CloudKit zone, and every existing kid simply has none of them.

**The admin's library seeding is not migrated, wrapped or refactored.** `LibrarySource` and its ISRC/UPC matching stay exactly as they are. They are a parent's shortcut for building allow and deny lists and have nothing to do with the kid's library beyond both involving the word.

Three things do meet what already exists, and each is a decision rather than a no-op.

**Existing plays are not backfilled into favorites.** The data is right there in `PlayEventRecord` and seeding from most-played would look generous. It would be wrong. A favorite is something a kid _said_, and manufacturing a hundred from a play log would put items on their shelf they never chose and then invite them to unfavorite things they never favorited. The library starts empty, and that emptiness is honest.

**A pre-existing Apple Music library is adopted on the first read**, becoming `origin: "appleLibrary"` rows. For a kid with their own account that is the whole point — it is their library and always was, and adopting it is the feature working on day one rather than starting them at zero.

It is also the one moment this feature can go badly wrong, because the same pass on a parent's account pulls an adult library onto a child's shelf. Three things stand between those outcomes, and none of them is the default:

1. **Onboarding asks before the first read happens** (see Invariants & limits). The parent answers the question while there is still nothing adopted, which is what makes `isSharedDevice = false` safe as a default rather than merely convenient.
2. **The policy engine judges every adopted row at render time.** Explicit and unrated content is filtered on a level 2 kid's shelf exactly as it is everywhere else, and shows up in the parent's report as blocks.
3. **Adopted rows carry **`origin: "appleLibrary"`, so the report can say which of a kid's favorites they chose and which arrived with the account. A shelf that filled itself is visible as such rather than looking like a very busy week.

**"Yours" changes meaning on the level 1 home screen.** It currently labels the parent's allow list. Once a kid has favorites and playlists, that word describes those, and the allow list needs another — "From your grown-up", or similar. A visible-string change with no stored data behind it, but it lands on the screen a level 1 kid sees most, so it ships with the shelf.

**Retention must learn about these tables before retention ships.** Open question 6 weighs a 90-day rolling window on child event data. Whatever is chosen, these are **not** events and must be exempt (see Invariants & limits). A sweep written against "child data older than 90 days" would delete a kid's playlists silently, months later, and they are the records in the whole store with the most work in them.

### Staged plan
**Stage 1 — the seam, with one provider.**

- Ships: `LibraryProvider`, `LibraryCapabilities`, the merged store, and `CloudKitLibraryProvider` — favorites on songs, albums and artists, plus playlist create, rename, reorder, add, remove and delete. The heart and the playlist UI. Local search over both. The allow-list rename. `liveProviders()` returns `[cloudKit]`.
- Does not: touch MusicKit. No `MusicLibrary` call, no subscription needed, no toggle yet.
- Exit test: a kid favorites an album and builds a playlist, force-quits, relaunches, and both are intact; a parent denies the artist and both vanish from the kid's screens while the rows survive in the store. All provable against stubs with no network and no device — which is the point of putting the seam in first.

**Stage 2 — the Apple Music provider, writing.**

- Ships: `isSharedDevice` as a real toggle in the admin, and `AppleMusicLibraryProvider` with writes — favorites, playlist creation, editing of playlists we created, `appleIsOurs` recorded at creation. Its `capabilities` are set from what the framework actually offers, which is where questions 1 and 3 get answered: by building it rather than by a separate probe.
- Does not: read the Apple library back. The kid's shelf is still exactly the CloudKit provider, so the browsing-source rule is not yet amended.
- Exit test: with the toggle off, a favorite and a playlist made in the app appear in the Music app on the same account; with it on, neither does. And **every capability the provider declines is invisible to the kid** — the shelf is identical whichever flags came back, which is the test that the seam is doing its job.

**Stage 3 — reading back.**

- Ships: the Apple provider's reads, ISRC/UPC resolution, adoption of `origin: "appleLibrary"` rows, the merged shelf. This is the stage that amends "the user's own library is never a browsing source", and it ships with that amendment written into the Catalog and Search Layer spec rather than after it. Question 2's number falls out of running it.
- Does not: use `MusicLibrarySearchRequest`; search stays a local predicate over merged rows. Does not reconcile drift.
- Exit test: a song added in the Music app appears on the kid's shelf and survives a relaunch as a stored row — and an **explicit** song added in the Music app is filtered off the shelf by the engine and appears in the parent's report as a block. The second half is the one that matters: it is the proof that opening this door did not open the other one.

**Stage 4 — the report.**

- Ships: favorites and playlists in the parent's activity report, with one-tap widening to the allow list — the affordance the report already offers for blocks.
- Does not: notify. There is no push story and a favorite is not urgent.
- Exit test: a week of a kid's favorites and playlist names reads as something a parent recognises.

**Not staged: reconciling drift.** Deliberately absent from this plan. The union means the kid's shelf is correct without it, and whether the Apple-side copy's incompleteness matters is not knowable until the thing is in use. It is a later pass over the same seam and needs no schema change to add.

### What this changes about rules already written
Two standing rules move. Both are recorded here rather than quietly contradicted, because each was written with a reason and each reason still partly holds.

### "The user's own library as a browsing source" is no longer never

The Catalog and Search Layer spec lists four MusicKit affordances deliberately never used, and this is one: _"It is a seeding input only; nothing the kid sees is read from it."_ The reason was that the account's library is unvetted — it is the parent's music, and surfacing it hands a kid whatever is in it.

That reason is exactly right for the case it describes and says nothing about a device whose library is the kid's own. The rule becomes conditional rather than absolute:

> The user's own library is not a browsing source **unless the library is the kid's own**, which is what `isSharedDevice == false` asserts.

And since that is the default, **the amendment is in force from first launch**. Three things carry the original protection into the new arrangement:

1. Onboarding asks before the Apple provider's first read, so a parent has said which case this device is in before anything is read at all.
2. The policy engine still judges every item read back. Even a kid's own library is filtered — an explicit song added in the Music app is blocked on the shelf and reported to the parent.
3. The read happens only through the provider seam, so there is exactly one place where the door opens rather than a call site per screen.

**The clause this does not touch** is the one about the admin. The library as a _seeding input_ for a parent building lists is unchanged, still `LibrarySource`, still ISRC/UPC matching, and no part of it runs through anything in this spec.

The other three never-used affordances are untouched: no personalized recommendations, no autoplay past the end of a queue, no radio or stations.

### "Yours" stops meaning the allow list

A visible-string change with no data behind it, noted because it is not cosmetic. On a level 1 home screen "Yours" currently labels the list a parent built. Once a kid has favorites and playlists of their own, that word describes those, and leaving it on the allow list would be the app telling a kid that someone else's choices are their own.

### A rule that does not move

**The policy engine is still the single authority**, and nothing in this feature is a permission (see Invariants & limits). Worth saying out loud because a library is exactly the kind of thing that grows into one by accident — "it is in their library, so surely they can play it" is a sentence someone will write eventually, and it is wrong. What is in the library and what a kid may play are two questions, and only one of them is the engine's.

### The shared-device toggle
One switch in the admin, behind the passcode, worded for the question it actually asks.

**What it means.** Not "do several people use this iPad" but _"is the Apple Music library on this device this kid's own?"_ Those come apart in the case the narrower wording misses: a hand-me-down phone only the kid uses, still signed in to a parent's Apple Account. One user, one device, someone else's library.

**Off (the default) — both providers.** Read from both and write to both, with CloudKit expanding whatever Apple Music returns. This is the case the feature exists for and the one most families are in.

**On — CloudKit only.** Read nothing from Apple Music, write nothing to it. The kid still gets favorites, playlists, a shelf and search over all of it, because CloudKit is always live.

**The default is safe because of when the question is asked, not because of which way it points.** Onboarding puts it before the Apple provider's first read, so a parent decides while there is still nothing adopted (see Migration & existing data). A default that had to survive being wrong for weeks would have to be the other one; a default that only covers "the question was somehow never answered" can be the useful one.

**Why it is a question and not a detection.** The app could fingerprint the signed-in iCloud account, but that identifies _which_ account, never _whose_ — and the iCloud account is not necessarily the account library writes reach. A parent knows the answer with certainty and can be asked once. Anything inferred would be a guess wearing the costume of a fact, which is the failure mode this codebase avoids everywhere else.

**What it says in onboarding.** Plain words, consequence stated both ways: leave it off and the kid's favorites and playlists become real Apple Music library objects that follow them to their account, and whatever is already in that library becomes theirs here; turn it on and everything lives in this app instead. Changeable whenever — turning it off later adopts the library at that point rather than losing anything.

**It never appears on the kid's side**, in any form. No indicator, no reduced-functionality message, no difference a kid could notice beyond what is on their shelf.

### Where favorites and playlists appear
**The heart.** On a song row it sits at the leading edge of the trailing controls, beside the play button; on a tile it goes in the text area. **Never on the artwork** — the app's standing rule is clipping yes, compositing never, and a heart burned onto Apple's pixels is exactly what that rule forbids. Filled and outline, no count, no animation a kid has to sit through.

It appears on songs, albums and artists alike, and reads the same on all three even though the primitive underneath differs by kind.

**Search results.** Every row and tile shows whether it is already favorited — a local set lookup against rows in memory, costing nothing and needing no request. The search screen gains no fourth tab: Artists, Songs and Albums are searches of the catalog, and a "Favorites" tab that searched something else entirely would be the odd one out.

**The home screen.** A "Yours" shelf holding favorites, and a playlists shelf beside it, both built the way Recent already is: resolved from stored identifiers in one batched request and filtered at render time. In level 1 these sit alongside the parent's list, which now has its own name.

**Playlists.** A kid makes one from the now-playing screen or from a song's row, names it with the keyboard, and reorders by dragging. Songs are added from anywhere a song appears. Playing one queues its songs in order — and the player re-checks every track immediately before it plays, which is what makes a playlist built weeks ago safe to press play on today.

A playlist name is free text a child typed. It syncs to their Apple Music library and appears in the parent's report, and both of those are worth saying out loud before the field is built rather than after.

**Library search.** A local predicate over merged rows, reached from the shelf rather than from the main search field. A kid with forty favorites does not need to search them; a kid with four hundred does, and that kid exists a year in.

**The parent's report.** A favorite is a stronger signal than a play — a play can be an accident and a favorite cannot — so favorites and playlists get their own lines, with one-tap widening to the allow list.

### Open questions this opens
Three, and **none of them gates the design**. Each changes only what the Apple Music provider turns out to be capable of, and a capability that provider lacks is one CloudKit still has (see Invariants & limits). They are measurements that tune behaviour at the margins, not decisions the architecture waits on. All should reach _Open Questions and Research Tasks_ alongside the existing numbered list.

**1. Does MusicKit Swift expose favoriting at all, and for which kinds?** Adding a song or album to the library is documented and certain. _Favoriting_ is not, and it is the only primitive an artist has — there is no "add artist to library" in Apple Music. The Apple Music API has ratings endpoints (`/v1/me/ratings/…`, love and dislike) and newer favorites endpoints, but whether the Swift framework surfaces either is unverified. If it does not, the provider reaches them through `MusicDataRequest`, which carries the user token to arbitrary endpoints. Whatever the answer, it lands as capability flags: `favoriteArtists` may simply be absent, and artist favorites then live in CloudKit alone.

**2. What is the real ISRC/UPC resolution rate?** Existing research question 2, promoted from _is library seeding worth offering_ to _does the kid's own library read back completely_. A poor rate used to mean an optional admin shortcut discarded more; now it means a kid adds a song in the Music app and it is not here. Bounded, though: it affects only what the Apple provider contributes to a read, never what is stored, because everything the kid does in this app lands in CloudKit first.

**3. Can a playlist we created be recognised as ours after a reinstall?** `appleIsOurs` lives in the CloudKit zone, so it survives a reinstall on the same family account — but a playlist created before this app existed, or on a device whose records were lost, reads as foreign forever and quietly stops accepting edits. Whether MusicKit has gained any way to ask since WWDC22 is worth one look before accepting that as permanent.

### Not a question, but worth stating

**This sends a child's taste data to Apple.** "Nothing leaves the device" is a legal position in CLAUDE.md aimed at our servers and third-party analytics, and Apple under the family's own account is neither. But it is a change in kind from an app that until now kept a child's listening entirely local, and it belongs in onboarding in the same breath as the shared-device toggle rather than being discovered later. The licence permits the use — §3.3.6(D) allows user metadata for a function "clearly disclosed to end users and directly relevant to the use of Your Application" — and _clearly disclosed_ is a condition, not a description.

## Review
_Not reviewed._

## Open notes
_None._
