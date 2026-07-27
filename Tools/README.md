# Tools

Spikes and throwaway probes. Code here is not shipped and does not need to be
pretty, but it should be runnable by someone else later.

Planned: `RatingProbe` — runs a spread of catalog searches and counts how many
results come back `.clean`, `.explicit`, or `nil`, broken down by genre and
release era.

That number decides two things: the default for `UnratedBehavior` in
PolicyEngine, and whether the catalog layer's over-fetch retry cap of 3 is
generous or nowhere near enough. Needs MusicKit enabled on the App ID and a
physical device.
