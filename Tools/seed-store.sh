#!/usr/bin/env bash
#
# Puts a store pulled off the phone into a simulator, under this build.
#
# The other half of Tools/backup-store.sh. That one reads; this one replaces a
# container, which is why it is a separate command rather than a flag — pull and
# clobber should not sit one typo apart.
#
#   Tools/seed-store.sh                       # newest backup → the booted simulator
#   Tools/seed-store.sh --simulator 'iPhone 17'
#   Tools/seed-store.sh --from ~/MusicBoxBackups/20260818-071142-device
#   Tools/seed-store.sh --no-build --no-launch
#   Tools/seed-store.sh --dry-run
#
# **Why this exists.** A read path that comes back empty looks the same whether
# the policy engine turned everything down or the catalog request was refused,
# and the difference only shows up at a size a real family produces — a 316-song
# playlist is one over Apple's 300-id cap, and no fixture anybody would think to
# write is that long. Running HEAD over the phone's own store answers it without
# installing onto the phone, which is the move you want to make last.
#
# Opening the store also migrates it, so this doubles as the pre-push migration
# check: back up, seed, launch, back the simulator up again, and compare the row
# counts. That is the only honest answer to "will this build eat the family's
# data" short of finding out on the device.
#
# **Simulator only, and that is structural.** Everything here goes through
# `simctl`, which cannot reach a physical device. There is no flag to point it
# at one and no code path that could.
#
# ## Four things to know before trusting a result
#
# **Launching mutates what you just seeded.** `Session.syncPass()` runs on launch
# and on every foreground; it sweeps activity past the retention window — a
# delete — and pushes pending changes. Row counts after a launch are allowed to
# be lower than the backup's. Never seed the only copy of anything.
#
# **The Keychain does not travel.** The admin passcode lives there so it survives
# a reinstall, and no container copy reaches it. The admin gate behaving as unset
# on the first run is not a fault in the seeded data.
#
# **The simulator is still not evidence** about playback, Screen Time, or how any
# of it feels. It is evidence about whether a read path returns rows.
#
# **Watch where the data goes.** `FamilyStore.container()` pins
# `cloudKitDatabase: .none`, so SwiftData will not mirror — but the app's own
# FamilySync engine is a separate thing, and this is a child's real history on a
# simulator that may be signed into an Apple Account. Worth watching once,
# deliberately, before it becomes a habit.

set -euo pipefail

BUNDLE_ID="com.thegoldenmule.auralsanbox"
BACKUP_ROOT="${MUSICBOX_BACKUP_DIR:-$HOME/MusicBoxBackups}"

# The same two the backup captures, and for the same reasons: Application
# Support holds `default.store`, Preferences holds the UserDefaults plist with
# DeviceLibraryState, the acting grown-up and the sync engine's state. Seeding
# one without the other gives you a family's library under another device's idea
# of which device it is.
CONTAINER_PATHS=("Library/Application Support" "Library/Preferences")
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/Apps/AuralSandbox/AuralSandbox.xcodeproj"
SCHEME="AuralSandbox"

die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m%s\033[0m\n' "$*"; }
step() { printf '\033[1m%s\033[0m\n' "$*"; }

DO_BUILD=1
DO_LAUNCH=1
DO_BACKUP=1
DRY_RUN=0
FROM=""
SIMULATOR=""

# --- finding the backup -----------------------------------------------------

newest_backup() {
    [ -d "$BACKUP_ROOT" ] || return 0
    # Directory names are timestamps, so lexical order is chronological. Only
    # directories that actually hold a store count — an aborted pull leaves one
    # that does not, and silently seeding an empty container would look like a
    # bug in the app rather than in the backup.
    local d
    for d in $(ls -1 "$BACKUP_ROOT" 2>/dev/null | sort -r); do
        if [ -f "$BACKUP_ROOT/$d/Library/Application Support/default.store" ]; then
            printf '%s' "$BACKUP_ROOT/$d"
            return 0
        fi
    done
}

check_backup() {
    local dir="$1"
    local store="$dir/Library/Application Support/default.store"

    [ -d "$dir" ] || die "No such backup: $dir"
    [ -f "$store" ] || die "No default.store in $dir

That is a pull that did not finish, or not a backup at all. Take one with:
  Tools/backup-store.sh --list"

    # A store that will not pass its own integrity check is a store whose
    # symptoms in the app are the copy's, not the code's — which is the most
    # expensive kind of afternoon there is.
    local integrity
    integrity=$(sqlite3 "$store" 'PRAGMA integrity_check;' 2>&1 | head -1)
    [ "$integrity" = "ok" ] || die "Refusing to seed: integrity_check said '$integrity'
  $store"

    # In WAL mode the most recent writes can live only in the sidecar, so a
    # backup missing it is missing whatever the kid did last. Not fatal — an
    # older store is still worth running — but it should never be a surprise.
    if [ ! -f "$store-wal" ]; then
        note "  note: no default.store-wal beside the store; the last writes may be absent"
    fi
}

# --- finding the simulator --------------------------------------------------

# Accepts a name or a UDID and answers with a UDID. Names are what a human has;
# UDIDs are what every later command wants, and resolving once means a typo
# fails here rather than three steps in.
resolve_simulator() {
    local wanted="$1"
    xcrun simctl list devices -j 2>/dev/null | python3 -c "
import json, sys
wanted = sys.argv[1]
data = json.load(sys.stdin)
matches, booted = [], []
for runtime, devices in data.get('devices', {}).items():
    for dev in devices:
        if not dev.get('isAvailable'): continue
        entry = (dev['udid'], dev.get('name','?'), runtime.rsplit('.',1)[-1], dev.get('state'))
        if dev.get('state') == 'Booted': booted.append(entry)
        if wanted and wanted in (dev['udid'], dev.get('name')): matches.append(entry)
# No name given: the booted one, if exactly one is booted. Anything else asks.
chosen = matches if wanted else booted
if len(chosen) == 1:
    print('\t'.join(chosen[0]))
elif not chosen:
    print('NONE')
else:
    print('MANY')
    for udid, name, rt, state in chosen:
        print(f'  {name}  ({rt})  {state}  {udid}', file=sys.stderr)
" "$wanted"
}

# Opens the window, not just the device.
#
# `simctl boot` boots a simulator **headlessly**. The device reaches Booted, the
# app installs, launches and runs — `launchctl list` will show it with a pid —
# and there is nothing on screen anywhere. Which produced exactly the report it
# should have: "I don't see a simulator. Did this work or not?"
#
# Simulator.app is a separate application from the device it shows, so it gets
# opened separately. Skipped under --no-launch: seeding to drive from Xcode's Run
# button should not take over a screen.
show_simulator() {
    [ "$DO_LAUNCH" = 1 ] || return 0
    open -a Simulator --args -CurrentDeviceUDID "$1" 2>/dev/null || true
}

boot_simulator() {
    local udid="$1" state="$2"
    if [ "$state" = "Booted" ]; then
        show_simulator "$udid"
        return 0
    fi
    note "  booting…"
    xcrun simctl boot "$udid" 2>/dev/null || true
    show_simulator "$udid"
    # No `bootstatus` on every Xcode, so poll. A simulator that never reaches
    # Booted is a broken simulator, and saying so beats hanging.
    local i
    for i in $(seq 1 60); do
        [ "$(xcrun simctl list devices -j | python3 -c "
import json,sys
for r, ds in json.load(sys.stdin).get('devices', {}).items():
    for d in ds:
        if d['udid'] == '$udid': print(d.get('state','')); break
")" = "Booted" ] && return 0
        sleep 1
    done
    die "Simulator $udid never finished booting."
}

# --- building --------------------------------------------------------------

build_and_install() {
    local udid="$1"

    step "Building HEAD for the simulator"
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -sdk iphonesimulator \
        -destination "id=$udid" \
        -quiet \
        > /dev/null || die "Build failed. Run it without -quiet to see why."

    local settings app
    settings=$(xcodebuild -showBuildSettings \
        -project "$PROJECT" -scheme "$SCHEME" -sdk iphonesimulator 2>/dev/null)
    app="$(printf '%s' "$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/$(printf '%s' "$settings" | awk -F' = ' '/ FULL_PRODUCT_NAME /{print $2; exit}')"

    [ -d "$app" ] || die "Built, but no .app where the build settings said: $app"

    note "  $app"
    xcrun simctl install "$udid" "$app" || die "simctl install failed."
    ok "  ✓ installed"
}

# --- the seed itself --------------------------------------------------------

# The data container does not exist until the app has run once.
#
# Installing creates the *bundle* container; `get_app_container … data` fails
# until something has actually launched. So the app is started and stopped for
# the side effect, before anything is written into it.
ensure_container() {
    local udid="$1"
    if xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data >/dev/null 2>&1; then
        return 0
    fi
    note "  first run, to create the container…"
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    sleep 4
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data >/dev/null 2>&1 \
        || die "The app has no data container on this simulator even after a launch.
Install it once from Xcode and try again."
}

# Copied into the container directly, rather than through `install_app_data`.
#
# **`simctl install_app_data` is the documented mechanism and it does not work
# here.** Tried, on iOS 26.5 / iPhone 17, in every shape the errors asked for: it
# wants an `AppDataInfo.plist` beside `AppData/` (its absence is its own error
# message), and it wants `CFBundleIdentifier` in it rather than the `BundleID`
# that older notes give — with the wrong key it claims the app is not installed,
# which is a lie you can disprove with `simctl listapps` in the next breath. With
# the right key it gets one step further and fails with
# `com.apple.containermanager code 55, "Could not get the existing data container
# location"` — for an app that is installed, has been launched, and whose data
# container `get_app_container` prints on request. Adding the `Documents` and
# `tmp` siblings it might have wanted changes nothing.
#
# So: terminate, replace the two directories, done. What this gives up is the one
# thing `install_app_data` did for free — terminating the app before swapping the
# container — so that is done explicitly first, and it matters: SwiftData holding
# the store open while it is replaced underneath is how you get a corrupt file
# and a puzzling afternoon.
seed() {
    local udid="$1" from="$2"

    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true

    local dest
    dest=$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data) \
        || die "Could not find the app's data container."

    local path
    for path in "${CONTAINER_PATHS[@]}"; do
        [ -d "$from/$path" ] || { note "  · $path — not in this backup"; continue; }
        # Removed rather than merged. A copy over the top leaves whatever the
        # simulator already had beside the seeded rows, and a store that is
        # half one family and half another is worse than either.
        rm -rf "$dest/$path"
        mkdir -p "$dest/$(dirname "$path")"
        cp -R "$from/$path" "$dest/$path"
        note "  ✓ $path"
    done

    ok "  ✓ container replaced"
}

# --- reporting --------------------------------------------------------------

# The counts the backup recorded, beside the counts now in the simulator. A seed
# that landed short is invisible from inside the app — it just looks like a
# family with less history — so it gets checked here instead.
compare_rows() {
    local from="$1" udid="$2"

    local seeded
    seeded=$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data 2>/dev/null) || return 0
    local seeded_store="$seeded/Library/Application Support/default.store"
    [ -f "$seeded_store" ] || { note "  (no store in the simulator container to compare)"; return 0; }

    printf '\n'
    printf '  %-30s %10s %10s\n' 'table' 'backup' 'seeded'
    printf '  %-30s %10s %10s\n' '------------------------------' '----------' '----------'

    local source_store="$from/Library/Application Support/default.store"
    local table a b
    for table in $(sqlite3 "$source_store" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%' ORDER BY name;" 2>/dev/null); do
        a=$(sqlite3 "$source_store" "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null || echo '?')
        [ "$a" = "0" ] && continue
        b=$(sqlite3 "$seeded_store" "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null || echo '?')
        if [ "$a" = "$b" ]; then
            printf '  %-30s %10s %10s\n' "$table" "$a" "$b"
        else
            printf '  \033[33m%-30s %10s %10s  ←\033[0m\n' "$table" "$a" "$b"
        fi
    done
    printf '\n'
    note "  A difference here before launching means the seed landed short."
    note "  After launching, lower counts are expected: syncPass sweeps old activity."
}

# --- arguments --------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:-}"; shift 2 ;;
        --simulator) SIMULATOR="${2:-}"; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        --no-launch) DO_LAUNCH=0; shift ;;
        --no-backup) DO_BACKUP=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done

# --- go ---------------------------------------------------------------------

[ -n "$FROM" ] || FROM="$(newest_backup)"
[ -n "$FROM" ] || die "No backup found under $BACKUP_ROOT

Take one first:
  Tools/backup-store.sh"

# Same rule backup-store.sh enforces on the way out, enforced here on the way
# in: a backup holds a child's real history and has no business in the tree, so
# a path inside it is a sign something already went wrong.
case "$FROM" in
    "$REPO"/*) die "Refusing to read a backup from inside the working tree: $FROM
It holds a child's real history and must not be in git." ;;
esac

check_backup "$FROM"

resolved=$(resolve_simulator "$SIMULATOR")
case "$resolved" in
    NONE) die "No simulator matched '${SIMULATOR:-<booted>}'.
See what is there:  xcrun simctl list devices available" ;;
    MANY) die "More than one matched. Pass --simulator with a UDID from above." ;;
esac

UDID=$(printf '%s' "$resolved" | cut -f1)
SIM_NAME=$(printf '%s' "$resolved" | cut -f2)
SIM_RUNTIME=$(printf '%s' "$resolved" | cut -f3)
SIM_STATE=$(printf '%s' "$resolved" | cut -f4)

printf '\n'
step "Seeding $SIM_NAME ($SIM_RUNTIME)"
note "  from    $FROM"
note "  udid    $UDID"
note "  commit  $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
printf '\n'

if [ "$DRY_RUN" = 1 ]; then
    note "--dry-run: nothing was changed."
    [ "$DO_BUILD" = 1 ] && note "  would build HEAD and install it"
    [ "$DO_BACKUP" = 1 ] && note "  would back up the simulator's current container first"
    note "  would replace the container with the store above"
    [ "$DO_LAUNCH" = 1 ] && note "  would launch $BUNDLE_ID"
    exit 0
fi

boot_simulator "$UDID" "$SIM_STATE"

# Before anything is replaced. What is in there may be the only copy of a state
# worth keeping, and this costs a second.
if [ "$DO_BACKUP" = 1 ]; then
    step "Backing up what is in the simulator now"
    "$REPO/Tools/backup-store.sh" --simulator "$UDID" >/dev/null 2>&1 \
        && note "  ✓ kept" \
        || note "  · nothing to keep (no container yet)"
fi

[ "$DO_BUILD" = 1 ] && build_and_install "$UDID"

step "Replacing the container"
ensure_container "$UDID"
seed "$UDID" "$FROM"

compare_rows "$FROM" "$UDID"

if [ "$DO_LAUNCH" = 1 ]; then
    step "Launching"
    # --console-pty, not --console: the plain one swallows print(). And the
    # bundle id really is missing a 'd' — the correctly-spelled one fails with
    # FBSOpenApplicationServiceErrorDomain code=4.
    xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" || true
else
    ok "Seeded. Press Run in Xcode, or:"
    note "  open -a Simulator --args -CurrentDeviceUDID $UDID"
    note "  xcrun simctl launch --console-pty $UDID $BUNDLE_ID"
fi
