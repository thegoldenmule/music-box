# Keeping Kids In The App (superseded draft)

**Status:** active

## Body
The uncomfortable part. Our sandbox is only a sandbox while the kid is inside our app. A kid who taps home and opens the Music app has the whole catalog. We should decide how far we go, and be straight with parents about the rest.

## Options, cheapest first

| Option | What it stops | Cost |
| --- | --- | --- |
| Passcode on the admin screen | Kid changing their own settings | None. Do this regardless. |
| Guided Access | Leaving the app at all, while it's on | Free, but the parent has to turn it on by hand every session. Realistically used for car trips, not daily. |
| Family Controls / Screen Time API | Music app and Safari shielded; kid can't delete our app or sign out of iCloud | Entitlement request to Apple, days to weeks of waiting, iOS only. |
| Tell the parent to set up Screen Time themselves | Same as above, roughly | Free for us, but it's a manual setup most parents won't complete. |

## On Family Controls

It's the only option that gives real tamper resistance, and the framework specifically blocks an authorized child from deleting the app or signing out of iCloud. But it costs a manual approval from Apple, per bundle ID and per Screen Time extension, with reported turnaround from a few days to several weeks. Apple checks that the use case is genuine parental control and that you aren't collecting usage data for advertising or profiling — relevant to how we describe our reporting feature.

It also doesn't exist on native macOS. Mac Catalyst only. So a Mac build has no lockdown story at all.

**Suggestion:** submit the entitlement request early even if v1 ships without it. The request costs nothing and the waiting is the expensive part. But don't let v1 block on it.

## What we tell parents

Say it plainly in onboarding and on the store page: this app controls what happens inside this app. If your kid can open the Music app, they can hear anything. Here's how to lock that down, with a one-tap link into the right Settings screen and a short walkthrough.

The temptation is to soften this because it undercuts the pitch. Don't. A parent who discovers the gap themselves feels lied to, and that's a one-star review and a refund. A parent who was told up front sees an app that respects them.

## A free extra layer

If the parent sets Screen Time's music restriction to Clean, Apple blocks explicit playback underneath us — including inside our app. That's a genuine second line of defense at no cost to us. The catch is it produces confusing failures (see What We Know About MusicKit), so we need to detect that case and explain it rather than surfacing a raw error. Recommend it in onboarding, but never rely on it — our own filtering has to stand on its own.

## References
_None._

## Child pages
_None._
