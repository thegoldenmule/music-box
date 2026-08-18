# Tools

Not shipped, and it does not need to be pretty — but it should be runnable by
someone else later, and some of it is now load-bearing rather than throwaway.
`ship` owns getting a build out (`SHIPPING.md` is its manual). The two store
scripts own the round trip below.

## The store round trip

Getting a family's real data under a new build, without installing that build on
the phone first:

```sh
Tools/backup-store.sh                 # phone → ~/MusicBoxBackups/<stamp>-device
Tools/seed-store.sh                   # newest backup → simulator, builds HEAD, launches
Tools/backup-store.sh --simulator …   # and back out, to compare row counts
```

Two commands rather than one with a `--restore` flag: the first only reads, the
second replaces a container, and those should not sit one typo apart. Backups
land outside the working tree and the scripts refuse to put them in it — they
hold a child's real search and play history.

**What it answers that nothing else does.** Shapes no fixture has: a 316-song
playlist opened empty, which is what a playlist looks like whether the policy
engine turned every song down or the catalog request was refused for being one
identifier over Apple's cap of 300. Nobody writing a fixture invents three
hundred and sixteen of anything. And because opening a store migrates it,
seeding one the installed build wrote is the pre-push check on whether this
build eats the family's data.

**What it does not answer.** How anything feels, playback, or Screen Time. The
simulator is not evidence for those and a seeded run does not make it one.

Read the header of each script before relying on it — between them they record
the Keychain not travelling, the retention sweep deleting rows the moment you
launch, and why `simctl install_app_data` is not what does the seeding.

Planned: `RatingProbe` — runs a spread of catalog searches and counts how many
results come back `.clean`, `.explicit`, or `nil`, broken down by genre and
release era.

That number decides two things: the default for `UnratedBehavior` in
PolicyEngine, and whether the catalog layer's over-fetch retry cap of 3 is
generous or nowhere near enough. Needs MusicKit enabled on the App ID and a
physical device.
