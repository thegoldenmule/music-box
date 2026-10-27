# Storage and Data Model (superseded draft)

**Status:** active

## Body
Small and boring on purpose. SwiftData locally, no server in v1. The tricky part isn't the schema, it's what we're allowed to persist from the catalog.

## The shape

```swift
Family
  └─ Kid
       name, birthYear, mode
       ├─ [PolicyEntry]   kind: allow | deny
       │                  itemType: artist | album | playlist | song
       │                  catalogID, displayName, artworkURL
       │                  addedAt, addedBy
       ├─ [SearchEvent]   term, at, resultCount, blockedCount
       └─ [PlayEvent]     songID, albumID, artistID
                          displayName, at, secondsPlayed
                          verdict: allowed | blocked(reason)
```

Allow and deny are one type with a flag rather than two types. They're the same shape and the policy engine reads both together, so splitting them just means writing every query twice.

## Why we cache names and artwork

A policy entry could store only the catalog ID and re-fetch everything. But then the admin's allow list is useless offline and needs a network round trip per row to render. So we keep the display name and artwork URL alongside the ID.

The MusicKit terms restrict what metadata we may store and what we may use it for, so confirm this is allowed before building on it. Keeping it to the minimum needed to render the parent's own list — which is a disclosed purpose directly relevant to the app — is the defensible position. Artwork should be referenced by URL and cached like any image, never copied into our own storage.

## Log volume

A kid listening an hour a day generates a few hundred events a month. Not a scale problem, but it's a child's browsing history sitting on a device, so:

- Pick a retention window and enforce it. Ninety days of detail, then roll up to weekly summaries and drop the events.
- Give the parent a delete-everything button that actually deletes everything.
- Debounce search logging so we store the term the kid settled on, not every keystroke.
- Keep it in the app's own store, not anywhere shared or exportable by accident.

## Leaving room for sync

We're not syncing in v1, but retrofitting CloudKit onto a schema that never expected it is painful. Cheap insurance now: stable UUIDs on everything, timestamps on every record, and no assumption that IDs are locally sequential. Costs nothing today, saves a migration later.

## References
_None._

## Child pages
_None._
