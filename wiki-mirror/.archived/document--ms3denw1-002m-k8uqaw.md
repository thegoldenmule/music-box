# Activity Log and Reports (superseded draft)

**Status:** active

## Body
Runs in all three modes. In level 3 it's the entire product; in levels 1 and 2 it's how a parent learns what their kid is into and whether the walls are in the right place.

## What we record

- **Searches.** The term, when, and how many results survived filtering. Debounced — log the term the kid settled on, not every keystroke, or the log is unreadable and three times the size.
- **Plays.** Song, artist, album, when, and how long they actually listened. Thirty seconds of a song is a different signal from all four minutes of it.
- **Blocks.** What they tried to reach and which rule stopped them. This is the most useful entry in the whole log — it's how a parent finds out their kid is curious about a band, which is usually the conversation worth having.

## What a parent actually reads

Nobody reads an event log. The raw data is there if they want it, but the default view is a weekly summary:

- Top artists and songs this week, with how much time on each.
- New things they tried that they hadn't before.
- What got blocked, grouped by artist, each with a one-tap "allow this" that writes straight to the allow list.
- Roughly how much time they spent listening.

The blocked list feeding directly back into the allow list is what makes level 1 practical over time. See Parent Admin (superseded draft).

## Where it lives, and the legal question

We're logging a child's search queries. That's COPPA territory in the US, plus state laws and the UK Age Appropriate Design Code if we ship abroad. Keeping every event on-device or in the family's own iCloud, with nothing on servers we run, sidesteps most of it — a strong argument for that architecture independent of engineering simplicity. If we go Kids Category, no third-party analytics touches any of this, and honestly we shouldn't send it anywhere regardless.

Also worth deciding early: how long we keep events, and whether the kid is told they're being logged. For an older kid on level 3, telling them is arguably the point — the deal is visibility, not surveillance. Get real answers before shipping; see open question 12.

## One caution

Apple reviews Family Controls entitlement requests partly on whether you're collecting usage data for profiling. A reporting feature is legitimate and expected in a parental-control app, but how we describe it in that request matters.

## References
_None._

## Child pages
_None._
