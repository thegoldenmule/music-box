# Build and Release Setup (superseded draft)

**Status:** active

## Body
Housekeeping, but two items here have multi-week lead times, so they go first, not last.

## Do these on day one

1. **Enable MusicKit on the App ID.** Developer portal, Identifiers, App Services, MusicKit. Native apps get automatic token handling once this is on — no server, no key, no developer token. Nothing works until it's enabled.
2. **Request the Family Controls distribution entitlement, if we want it at all.** Reported turnaround runs days to weeks. It's free to ask and expensive to wait for. See Keeping Kids In The App (superseded draft).

## Targets

- iOS 15+ for MusicKit generally, but `ApplicationMusicPlayer` needs iOS 15 and **macOS 14**. The Mac floor is Sonoma; there's no way around it if we want in-app playback.
- One SwiftUI codebase across both. The kid player and admin are both simple enough that a shared UI layer is realistic — the differences are in lockdown, which the Mac doesn't have anyway.
- Background audio mode in Info.plist, or playback stops when the app backgrounds.
- Microphone and speech recognition entitlements if we do voice search.

## App Store setup

- Age rating, and whether we enter the Kids Category. See open question 11 — this is a real decision with permanent consequences, not a checkbox.
- Privacy nutrition labels. We collect a child's search and listening history. Even kept entirely on-device, this has to be declared accurately.
- A privacy policy that covers children's data, whatever we end up doing.
- Screenshots that show real playback, since the MusicKit terms restrict using Apple Music artwork outside of playback and playlist contexts.

## Testing setup

Needed before we can trust anything: a real Family Sharing group with a genuine under-13 child account, an Apple Music Family plan, and at least one physical device — the simulator's MusicKit story is unreliable and Screen Time behavior can't be tested there at all. Set this up early; it takes longer than expected and half the open questions can't be answered without it.

## References
_None._

## Child pages
_None._
