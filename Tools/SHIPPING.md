# Getting a build out

`Tools/ship` walks this app from a clean checkout to a TestFlight build, and
tells you what to do when it cannot. It is the equivalent of the `build_kit`
Godot addon in the sibling `godot-addons` repo, rebuilt for a native Xcode
project and for being called by something that is not a person.

Stdlib Python 3, no install step, no dependencies. `Tools/ship doctor` works on
a fresh clone with nothing but Xcode present.

```sh
Tools/ship doctor      # what is broken, and how to fix each row
Tools/ship next        # the one thing to do now
Tools/ship release     # tests → bump → archive → verify → export → verify → upload
Tools/ship status      # has Apple finished, and can anyone actually install it
```

## First run

```sh
Tools/ship doctor
```

Fifteen rows, each a place a release fails, each carrying the steps that clear
it. Rows this tool can repair say so; rows only a human can clear say that
instead, and never offer a button that does nothing.

The one thing worth doing before anything else is the App Store Connect API
key. Without it the pipeline still works — `xcodebuild` rides the Xcode login
session — but nothing can be checked *before* a build and no build state can be
read *after* one, which is most of the reason this tool exists.

```sh
# App Store Connect → Users and Access → Integrations → ＋
#   role: App Manager reads state and uploads.
#   Admin is what cloud signing is reported to need — and a key's role cannot
#   be changed after it is created, so if this machine has no distribution
#   certificate of its own, make it Admin.
Tools/ship auth import ~/Downloads/AuthKey_ABC123DEFG.p8
Tools/ship auth set-issuer 69a6de78-....
```

The `.p8` is copied to `~/private_keys/` (chmod 600, outside any repo) and only
its id and a home-relative path are written down, into a `.env` the tool checks
is gitignored first. Apple lets a `.p8` be downloaded exactly once.

## Commands

| | |
|---|---|
| `doctor [--offline]` | the checklist. `--offline` skips the App Store Connect probes |
| `fix <id>` | apply a repair the checklist offered; no argument lists them |
| `next` | the single next action, as data — the loop to drive |
| `release` | the whole pipeline, ending in an upload |
| `build` | the same, stopping at a signed `.ipa` on disk |
| `upload [ipa]` | send an already-built `.ipa` without rebuilding |
| `verify [path]` | read the keys back out of an artifact |
| `status` | what App Store Connect says about this app's builds |
| `bump [n]` | set or advance `CURRENT_PROJECT_VERSION` |
| `auth show \| import \| set-issuer` | the API credentials |
| `info` | the resolved project facts |
| `selftest` | this tool's own unit tests |

## Driving it from a script or an agent

Every command takes `--json` and prints exactly one object on stdout. All
prose, progress and subprocess output goes to stderr, so the two never mix and
`Tools/ship doctor --json | jq` works while a build scrolls past.

```
0  ok
1  failed — something the tool tried did not work
2  usage error
3  blocked on a human: a step no tool can perform. Retrying will not help.
```

Exit 3 is the important one. Creating an app record, accepting an agreement,
enabling a capability in the portal — a caller that retries on failure must not
spin on these.

`next` is the loop:

```sh
while :; do
  step=$(Tools/ship next --json)
  case $(jq -r .data.next.kind <<<"$step") in
    done)   break ;;
    manual) jq -r .guidance <<<"$step"; break ;;
    run)    eval "$(jq -r .data.next.command <<<"$step")" || break ;;
  esac
done
```

Its ordering is the design: not most-severe-first, but the order in which doing
one thing stops being wasted effort. Repairable failures come before manual
ones, because a repair may clear the row below it. Credentials come before
optional repairs, because without them every later decision is made blind. The
dirty-tree check comes last, because it does not matter until something is
about to be uploaded.

## Three decisions worth knowing about

**The export writes a file, and the upload sends that file.** The single
command everyone reaches for is `-exportArchive` with `destination: upload`,
which signs and uploads in one step and leaves nothing to inspect. This repo's
rule is to verify the artifact and never the settings, and that needs an
artifact. So the export lands on disk, `verify` reads its Info.plist and its
signature, and only then does `altool` send those exact bytes.
`--upload-with xcodebuild` restores the one-step path and says out loud that
nothing was checked.

**The build number is a command-line override on the archive, not a file
edit.** `CURRENT_PROJECT_VERSION[sdk=…]` is a legal spelling that takes
precedence over the plain one and is invisible to a regex written for the plain
one — a file edit would report success while the shipped build kept the old
number. The override wins over both, and a failed archive leaves no dirty
project file. The number is written back only after a successful upload, so the
repo records what shipped rather than what was attempted. (`bump` still edits
the file, and refuses outright when it finds the conditional form.)

**`verify` reads artifacts, because settings lie.** This project has been bitten
twice: `IPHONEOS_DEPLOYMENT_TARGET[sdk=iphone*]` resolved to the SDK default
while every report said 17.0, and `INFOPLIST_KEY_UIBackgroundModes` appeared in
`-showBuildSettings` and never reached the generated plist. Neither failed to
compile. So `verify` compares *every* key the source partial Info.plist declares
against the built one, and every entitlement the source file asks for against
the signature — the general form of both bugs, so it catches the next one too.

One difference between source and artifact is expected and asserted rather than
ignored. `aps-environment` comes from the provisioning profile's allowlist, not
from the entitlements file, and a distribution profile always says `production`.
The source file saying `development` is correct and must not be changed — that
is the classic wrong fix for ITMS-90164 and it breaks local development. What
matters is the exported binary, measured: archive `development`, export
`production`.

## What it cannot do

- **Create the app record.** Genuinely absent from Apple's API. `doctor` says
  so with a link, and exits 3.
- **Confirm MusicKit.** It is an App Service, not a bundle-id capability: there
  is no `MUSIC_KIT` value in Apple's enum and it appears in no provisioning
  profile, so neither this tool nor a successful signed build can see it. The
  row says it cannot be checked rather than guessing it is off. Same for Family
  Controls. The only real proof is a catalog request on a device that comes
  back — and a well-formed API error counts, while an authorization failure
  does not.
- **Tell you whether the CloudKit schema is deployed to Production.** An App
  Store export puts the container in Production. If the family zone exists only
  in Development, testers get a failing store and nothing in the build log says
  so.

## Where things live

| | | |
|---|---|---|
| shared settings | `Tools/ship.config.json` | committed; only what cannot be derived from the project |
| credentials | `<repo>/.env` | gitignored, chmod 600 |
| the `.p8` | `~/private_keys/` | outside any repo, referenced home-relative |
| archives, `.ipa`s, logs | `Apps/AuralSandbox/build/ship/` | covered by the existing `build/` ignore rule |

Environment variables (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`) take
precedence over the `.env`, so CI can inject credentials without writing
anything to disk.

Almost nothing needs configuring: the bundle identifier, team, versions and
deployment target are already in the Xcode project, and a config file that
restated them would be a second source of truth that drifts.

## Extending it

- **A failure you had to diagnose by hand** belongs in `shipkit/classify.py` as
  a signature plus the steps that cleared it, so the next person gets a sentence
  instead of a log. Rules are most-specific-first and the first match wins.
- **A check** is a function of `Facts` returning a `Row`, added to `CHECKS` in
  `shipkit/preflight.py`. A row that this tool cannot repair must set
  `manual=True` and leave `fix` empty.
- **A repair** goes in `FIXES` in the same file, keyed by the row id.

`Tools/ship selftest` runs the unit tests. They are stdlib `unittest` and cover
the pure parts: the `.env` rewrite, the build-number regex and the conditional
form it must refuse, the JWT signature conversion, the classifier's ordering,
the export options, and `next`'s decision order.
