# Accounts, Devices and Sync (superseded draft)

**Status:** active

## Body
Who's who, which device is which, and how settings get to the kid while the log comes back. The least glamorous piece and probably the one that eats the most time.

## The Apple Music situation

MusicKit plays under whichever Apple Account is signed into the device. That gives us two setups, and they behave very differently:

- **Shared account.** Kid uses the parent's Apple ID on a hand-me-down iPad. Works immediately, no setup. But the kid's listening lands in the parent's history and recommendations, which parents notice and dislike.
- **Child account under Family Sharing.** The right answer. Kids under 13 can have their own Apple Account, and an Apple Music Family plan gives each member their own library, history, and recommendations. More setup, cleaner in every other way.

Assume the second, support the first. And verify the whole flow actually works on a real child account before assuming it does — see open question 5.

## Getting settings from parent to kid

Different Apple Accounts means plain iCloud sync won't carry data between them. The options:

| Approach | Upside | Downside |
| --- | --- | --- |
| Parent configures the kid's device directly | No sync at all. Ships now. | Parent has to physically hold the iPad to change anything. |
| CloudKit with CKShare | No server, stays in the family's iCloud, good for the privacy story. | Needs a custom record zone, share acceptance flow, and the SwiftData integration is reportedly rough. Prototype before committing. |
| Our own server | Full control, easy multi-device. | We now store children's data, which drags COPPA and friends into scope. Avoid if we can. |

Recommendation: ship v1 with no sync at all. It removes an entire category of work and legal exposure, and single-device families are the common case anyway. Add CloudKit sharing once the rest works, and prototype it in a throwaway project first.

## Device roles

Each install is a parent device, a kid device, or both. On a kid device the app launches into the player and admin is behind the gate. On a parent-only device there's no player at all. Getting this wrong — defaulting a fresh install to "both" — means a kid device where the admin is one tap away.

## Things that will come up

- Two kids on one iPad. Switching profiles has to be a parent action, or the younger kid just uses the older kid's settings.
- A kid who ages up. Modes need to change without losing history.
- Subscription lapses. The app has to say so clearly rather than showing an empty catalog.
- Parent gets a new phone. Whatever we build needs a recovery path that isn't "start over."

## References
_None._

## Child pages
_None._
