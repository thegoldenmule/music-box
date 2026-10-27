# Catalog and Search Layer (superseded draft)

**Status:** active

## Body
Everything that touches MusicKit lives here, so the rest of the app never talks to Apple directly. That keeps the policy engine testable and gives us one place to swap the backend if MusicKit doesn't work out.

## What it does

- Authorization and subscription state. Ask for permission, watch `MusicSubscription.subscriptionUpdates`, and tell the app plainly when there's no subscription rather than failing at play time.
- Search the catalog for artists, albums, songs, and playlists.
- Look up items by ID — how a saved allow list entry turns back into something playable.
- Expand things: artist to albums, album to tracks, playlist to entries.
- Fetch the ancestry the policy engine needs to judge an item.

## Over-fetching, because search can't filter

MusicKit search takes a term, types, a limit, and an offset. There is no way to ask for clean results only. So the loop is: request more than we need, run every result through the policy engine, keep what survives, and go back for more if we came up short. Cap the retries so a search for something with no clean results anywhere doesn't spin forever — return an honest empty state instead.

The multiplier needs measuring, not guessing. See open question 6.

## Caching

We need to cache aggressively: ancestry lookups are the difference between a snappy list and a stalled one, and allow list entries need names and artwork to render in the admin without a network round trip. But the MusicKit terms restrict what we may store and what we may use metadata for, so this needs a real answer before we build a persistent cache — see open question in the research list. Safe starting point: an in-memory cache for the session, plus persisting only the IDs and display names we genuinely need for allow lists.

## Failure modes to handle properly

- No subscription, or subscription lapsed mid-session.
- Authorization denied or revoked in Settings.
- Offline. There's no download story under the MusicKit terms, so offline means the app doesn't work — say so clearly instead of showing empty lists.
- Playback refused by something outside our app, such as Screen Time or Apple Music parental controls. This produces confusing errors and parents will blame us. Detect it and explain it.
- An item on the allow list that has vanished from the catalog. Show it as unavailable in the admin rather than silently dropping it.

## Things to deliberately not use

- Personalized recommendations. Built from history, unvetted by definition.
- Autoplay past the end of a queue. It wanders into territory nobody approved.
- Radio and stations, at least in v1, for the same reason.
- The user's own library, unless we decide a kid should have one. Library content bypasses catalog ratings and is a separate can of worms.

## References
_None._

## Child pages
_None._
