#!/usr/bin/env bash
#
# Pulls the app's data off a device or simulator and verifies it landed intact.
#
# Run this before installing a build that changes the schema. Opening a SwiftData
# store migrates it in place, so the first launch of a new build is the moment a
# family's curation is at risk, and there is no undo.
#
#   Tools/backup-store.sh                      # the connected device, if there is one
#   Tools/backup-store.sh --list               # what is reachable right now
#   Tools/backup-store.sh --device 'Atticus’s iPhone'
#   Tools/backup-store.sh --simulator DF8F5B33-E54F-4268-8253-16B104B2EAE7
#   Tools/backup-store.sh --simulators         # every simulator holding the app
#
# **Backups land outside the repo, and that is deliberate.** They contain a
# child's real search and play history. Nothing in this project's rules survives
# that being committed to git by accident, so the default is a directory in
# $HOME and there is no flag to put it under the working tree.
#
# **What this does NOT capture: the Keychain.** The admin passcode lives there so
# it survives a reinstall, and no container download reaches it. If you need a
# restore that puts the admin gate back exactly as it was, take an *encrypted*
# Finder backup as well — the encryption checkbox is what makes Apple include
# Keychain items.

set -euo pipefail

BUNDLE_ID="com.thegoldenmule.auralsanbox"
OUT_ROOT="${MUSICBOX_BACKUP_DIR:-$HOME/MusicBoxBackups}"

# The two places the app's own state lives inside its container. Application
# Support holds `default.store`; Preferences holds the UserDefaults plist, which
# carries DeviceLibraryState, the acting grown-up and the sync engine's state —
# device-local things that never sync and so exist nowhere else.
CONTAINER_PATHS=("Library/Application Support" "Library/Preferences")

die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m%s\033[0m\n' "$*"; }

stamp() { date +%Y%m%d-%H%M%S; }

# --- what is out there ------------------------------------------------------

list_devices() {
    xcrun devicectl list devices 2>/dev/null || true
}

# Simulator containers are found by reading each app container's metadata rather
# than by asking simctl, so this works for shut-down simulators too.
list_simulator_containers() {
    local meta id
    for dir in "$HOME/Library/Developer/CoreSimulator/Devices"/*/data/Containers/Data/Application/*/; do
        meta="$dir/.com.apple.mobile_container_manager.metadata.plist"
        [ -f "$meta" ] || continue
        id=$(plutil -extract MCMMetadataIdentifier raw -o - "$meta" 2>/dev/null) || continue
        [ "$id" = "$BUNDLE_ID" ] || continue
        [ -f "$dir/Library/Application Support/default.store" ] || continue
        printf '%s\n' "$dir"
    done
}

simulator_name_for_container() {
    # .../Devices/<UDID>/data/Containers/... — pull the UDID back out and ask
    # simctl what it is called, so the manifest names a simulator a human
    # recognises rather than a UUID.
    local udid
    udid=$(printf '%s' "$1" | sed -E 's|.*/Devices/([^/]+)/data/.*|\1|')
    local name
    name=$(xcrun simctl list devices -j 2>/dev/null \
        | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for runtime, devices in d.get('devices', {}).items():
    for dev in devices:
        if dev.get('udid') == '$udid':
            print(dev.get('name','?'), '/', runtime.rsplit('.',1)[-1])
" 2>/dev/null) || true
    printf '%s (%s)' "${name:-simulator}" "$udid"
}

# --- verifying what we got --------------------------------------------------

# Checks the COPY, never the source. Opening a WAL-mode SQLite file can
# checkpoint it, which rewrites the very thing we are trying to preserve.
verify_store() {
    local store="$1" manifest="$2"

    if [ ! -f "$store" ]; then
        printf 'MISSING: no default.store in this backup\n' >> "$manifest"
        return 1
    fi

    {
        printf '\n## default.store\n\n'
        printf 'integrity_check: '
        sqlite3 "$store" 'PRAGMA integrity_check;' 2>&1 | head -5
        printf '\nrow counts:\n'
        # Every Core Data / SwiftData table, so a shape change shows up here
        # without this script having to know the schema.
        sqlite3 "$store" "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%' ORDER BY name;" 2>/dev/null \
            | while read -r table; do
                [ -n "$table" ] || continue
                count=$(sqlite3 "$store" "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null || echo '?')
                [ "$count" = "0" ] && continue
                printf '  %-34s %s\n' "$table" "$count"
            done
    } >> "$manifest"
}

write_manifest() {
    local dest="$1" source_desc="$2" manifest="$dest/MANIFEST.md"

    {
        printf '# Music Box backup\n\n'
        printf -- '- taken: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf -- '- source: %s\n' "$source_desc"
        printf -- '- bundle: %s\n' "$BUNDLE_ID"
        printf -- '- repo HEAD at backup time: %s\n' \
            "$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
        printf '\n'
        printf 'The commit the *installed app* was built from is not recorded anywhere\n'
        printf 'on the device, so it cannot be captured here. The line above is the\n'
        printf 'checkout that ran the backup, which is a hint and not the answer.\n'
        printf '\n## files\n\n'
        # -wal matters as much as the store: in WAL mode the most recent writes
        # can live only there, so a backup missing it is missing whatever the
        # kid did last.
        ( cd "$dest" && find . -type f ! -name MANIFEST.md -exec ls -l {} \; \
            | awk '{printf "  %-12s %s\n", $5, $NF}' | sort -k2 )
        printf '\n## checksums\n\n'
        ( cd "$dest" && find . -type f ! -name MANIFEST.md -print0 \
            | xargs -0 shasum -a 256 2>/dev/null | sed 's/^/  /' )
    } > "$manifest"

    verify_store "$dest/Library/Application Support/default.store" "$manifest" || true
    printf '%s' "$manifest"
}

report() {
    local dest="$1" manifest="$2"
    ok "Backed up to $dest"
    note ''
    sed -n '/^## default.store/,$p' "$manifest" | sed 's/^/  /'
    note ''
    local store="$dest/Library/Application Support/default.store"
    if [ -f "$store" ]; then
        local wal="$store-wal"
        if [ -f "$wal" ] && [ -s "$wal" ]; then
            note "  note: default.store-wal is non-empty — it is part of the data, keep it with the store."
        fi
    fi
}

# --- the two ways of getting it ---------------------------------------------

backup_device() {
    local device="$1"
    local dest="$OUT_ROOT/$(stamp)-device"
    mkdir -p "$dest"

    note "Pulling from device: $device"
    local got_any=0
    for path in "${CONTAINER_PATHS[@]}"; do
        # `devicectl` copies the CONTENTS of --source into --destination, not the
        # directory itself. Pointing both sources at a shared parent therefore
        # merges them into one flat directory, which loses which file came from
        # where — so each gets its own destination mirroring the container.
        mkdir -p "$dest/$path"
        if xcrun devicectl device copy from \
            --device "$device" \
            --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" \
            --source "$path" \
            --destination "$dest/$path" \
            --quiet 2>/dev/null
        then
            got_any=1
            note "  ✓ $path"
        else
            note "  · $path — not present, or not readable"
        fi
    done

    [ "$got_any" = 1 ] || {
        rm -rf "$dest"
        die "Could not read the app's container.

The usual cause is that the installed build is not development-signed —
a TestFlight or App Store install will not hand over its container. In
that case take an encrypted Finder backup instead.

Check the app is installed and the device is unlocked and trusted:
  xcrun devicectl device info apps --device '$device' | grep -i auralsanbox"
    }

    local manifest; manifest=$(write_manifest "$dest" "device: $device")
    report "$dest" "$manifest"
}

backup_simulator_container() {
    local container="$1"
    local desc; desc=$(simulator_name_for_container "$container")
    local dest="$OUT_ROOT/$(stamp)-simulator"
    # More than one simulator can hold the app; keep them apart.
    local n=1
    while [ -e "$dest" ]; do dest="$OUT_ROOT/$(stamp)-simulator-$((++n))"; done
    mkdir -p "$dest"

    note "Copying from simulator: $desc"
    for path in "${CONTAINER_PATHS[@]}"; do
        if [ -d "$container/$path" ]; then
            mkdir -p "$dest/$(dirname "$path")"
            cp -R "$container/$path" "$dest/$(dirname "$path")/"
            note "  ✓ $path"
        else
            note "  · $path — not present"
        fi
    done

    local manifest; manifest=$(write_manifest "$dest" "simulator: $desc")
    report "$dest" "$manifest"
}

# --- arguments --------------------------------------------------------------

MODE=auto
TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --list) MODE=list; shift ;;
        --device) MODE=device; TARGET="${2:-}"; shift 2 ;;
        --simulator) MODE=simulator; TARGET="${2:-}"; shift 2 ;;
        --simulators) MODE=simulators; shift ;;
        --out) OUT_ROOT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done

case "$OUT_ROOT" in
    "$PWD"*|*/aural-sandbox/*)
        die "Refusing to write a backup inside the working tree: $OUT_ROOT
It holds a child's real history and must not end up in git." ;;
esac

mkdir -p "$OUT_ROOT"

case "$MODE" in
    list)
        printf '\nDevices:\n\n'
        list_devices | sed 's/^/  /'
        printf '\nSimulators holding %s:\n\n' "$BUNDLE_ID"
        found=0
        while read -r c; do
            [ -n "$c" ] || continue
            found=1
            printf '  %s\n' "$(simulator_name_for_container "$c")"
            printf '    %s\n' "$c"
        done < <(list_simulator_containers)
        [ "$found" = 1 ] || printf '  (none)\n'
        printf '\n'
        ;;

    device)
        [ -n "$TARGET" ] || die "--device needs a name, UDID or identifier (see --list)"
        backup_device "$TARGET"
        ;;

    simulator)
        [ -n "$TARGET" ] || die "--simulator needs a simulator UDID (see --list)"
        container=$(list_simulator_containers | grep -F "/Devices/$TARGET/" | head -1) \
            || die "No container for simulator $TARGET"
        [ -n "$container" ] || die "Simulator $TARGET has no install of $BUNDLE_ID"
        backup_simulator_container "$container"
        ;;

    simulators)
        found=0
        while read -r c; do
            [ -n "$c" ] || continue
            found=1
            backup_simulator_container "$c"
        done < <(list_simulator_containers)
        [ "$found" = 1 ] || note "No simulator holds $BUNDLE_ID."
        ;;

    auto)
        # Exactly one connected device is the unambiguous case and the common
        # one. Anything else asks rather than guessing which family's data to
        # take.
        connected=$(list_devices | awk '$0 ~ /connected/ {print}' | sed -E 's/^([^ ].*[^ ])[[:space:]]{2,}.*coredevice.*/\1/' | head -5)
        count=$(printf '%s\n' "$connected" | grep -c . || true)
        if [ "$count" = "1" ]; then
            backup_device "$(printf '%s' "$connected")"
        elif [ "$count" = "0" ]; then
            note "No device connected. Simulators holding the app:"
            "$0" --list
            die "Pass --device or --simulator (or --simulators for all of them)."
        else
            note "More than one device is connected:"
            printf '%s\n' "$connected" | sed 's/^/  /'
            die "Pass --device '<name>' to say which."
        fi
        ;;
esac
