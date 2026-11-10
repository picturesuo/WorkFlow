#!/bin/zsh
# Times a standalone launch of a perf build of WorkFlow: process start to
# launch_ready (end of applicationDidFinishLaunching), to the first window
# appearing (if one does), and to engine_ready (speech model loaded).
#
# Usage: cold-launch.sh APP BUNDLE_ID OUT_JSONL [RUNS]
#
# APP must be built with BUNDLE_ID, and BUNDLE_ID must start with
# com.picturesuo.WorkFlow.fmtest.perf so the launch never reads WorkFlow's own
# preferences or History. The app is opened in the background (open -g), its
# defaults domain is seeded so launch is silent, and both the domain and its
# Application Support folder are deleted afterwards.
#
# BLOCKED BY DEFAULT: applicationDidFinishLaunching always runs the legacy
# credential migration, and its Keychain service names are fixed to
# com.picturesuo.WorkFlow.* whatever the bundle identifier is, so even a perf
# build queries the owner's real WorkFlow Keychain items (and may raise a
# Keychain access dialog). The script refuses to launch unless
# WF_PERF_ALLOW_STANDALONE_LAUNCH=1, to be set only once that read is gone.
set -euo pipefail

if (( $# < 3 )); then
    print -u2 "usage: cold-launch.sh APP BUNDLE_ID OUT_JSONL [RUNS]"
    exit 2
fi
APP=${1:A}
BUNDLE_ID=$2
OUT_JSONL=${3:A}
RUNS=${4:-10}
SCRIPT_DIR=${0:A:h}

note() {
    print -r -- "{\"note\": \"$1\"}" >> "$OUT_JSONL"
    print -u2 -r -- "cold-launch: $1"
}

if [[ $BUNDLE_ID != com.picturesuo.WorkFlow.fmtest.perf* ]]; then
    print -u2 "cold-launch: refusing bundle id $BUNDLE_ID (must start with com.picturesuo.WorkFlow.fmtest.perf)"
    exit 2
fi
actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [[ $actual_id != "$BUNDLE_ID" ]]; then
    print -u2 "cold-launch: $APP has bundle id $actual_id, not $BUNDLE_ID"
    exit 2
fi
mkdir -p "${OUT_JSONL:h}"

if [[ ${WF_PERF_ALLOW_STANDALONE_LAUNCH:-} != 1 ]]; then
    note "Cold launch not measured: a standalone launch runs the legacy credential migration, which queries the owner's real com.picturesuo.WorkFlow Keychain items whatever the bundle id. Set WF_PERF_ALLOW_STANDALONE_LAUNCH=1 only after that is fixed."
    exit 3
fi

# Silent launch in this bundle id's own domain: onboarding done, hidden in the
# menu bar, no login item, no shortcut (no Carbon hotkey, no event tap, so no
# Input Monitoring prompt), and no legacy preference import.
seed_defaults() {
    defaults write "$BUNDLE_ID" hasCompletedOnboarding -bool true
    defaults write "$BUNDLE_ID" startHiddenInMenuBar -bool true
    defaults write "$BUNDLE_ID" launchAtLogin -bool false
    defaults write "$BUNDLE_ID" KeyboardShortcuts_toggleRecord -bool false
    defaults write "$BUNDLE_ID" KeyboardShortcuts_escape -bool false
    defaults write "$BUNDLE_ID" modifierOnlyHotkey -string none
    defaults write "$BUNDLE_ID" secondaryModifierOnlyHotkey -string none
    defaults write "$BUNDLE_ID" mouseButtonHotkey -string none
    defaults write "$BUNDLE_ID" modifierChordHotkey -string none
    defaults write "$BUNDLE_ID" playSoundOnRecordStart -bool false
    defaults write "$BUNDLE_ID" bedrockCleanupEnabled -bool false
    defaults write "$BUNDLE_ID" didMigratePreferencesToWorkFlow -bool true
    defaults write "$BUNDLE_ID" selectedEngine -string fluidaudio
    defaults write "$BUNDLE_ID" fluidAudioModelVersion -string v3
}

cleanup_identity() {
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    local support="$HOME/Library/Application Support/$BUNDLE_ID"
    if [[ $BUNDLE_ID == com.picturesuo.WorkFlow.fmtest.perf* && -d $support ]]; then
        rm -rf -- "$support"
    fi
}

# Cleanup deletes this identity's preferences and Application Support folder,
# so refuse an identity that already has either: it was not created here.
if defaults read "$BUNDLE_ID" >/dev/null 2>&1 || [[ -e "$HOME/Library/Application Support/$BUNDLE_ID" ]]; then
    print -u2 "cold-launch: identity $BUNDLE_ID already has data; refusing so nothing this run did not create is deleted"
    exit 2
fi
trap cleanup_identity EXIT

scratch=$(mktemp -d "${TMPDIR:-/tmp}/workflow-cold-launch.XXXXXX")
visible_windows="$scratch/visible-windows"
xcrun swiftc -O -o "$visible_windows" "$SCRIPT_DIR/visible-windows.swift"

seed_defaults

# One launch: prints a JSON line with the three timings.
launch_once() {
    local run=$1 warmup=$2
    local events="$scratch/run-$run.jsonl"
    rm -f "$events"
    local front_before front_after
    front_before=$(lsappinfo front)
    open -g -n --env "WF_PERF_OUT=$events" "$APP"

    local pid="" deadline=$(( SECONDS + 120 ))
    while (( SECONDS < deadline )); do
        if [[ -s $events ]]; then
            pid=$(python3 -I -c 'import json,sys
for line in open(sys.argv[1]):
    print(json.loads(line)["pid"]); break' "$events")
            grep -q '"engine_ready"' "$events" && break
        fi
        sleep 0.2
    done
    if [[ -z $pid ]]; then
        pkill -TERM -f "$APP/Contents/MacOS/" 2>/dev/null || true
        note "launch $run never wrote an event"
        return 1
    fi

    front_after=$(lsappinfo front)
    local shown
    shown=$("$visible_windows" "$pid" || true)
    if [[ $front_before != "$front_after" || -n $shown ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        note "launch $run moved focus or showed a window (front before $front_before, after $front_after, windows: ${shown:-none}); stopped"
        return 4
    fi

    kill -TERM "$pid" 2>/dev/null || true
    local exit_deadline=$(( SECONDS + 20 ))
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < exit_deadline )); do sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
        note "launch $run did not exit on TERM"
        return 1
    fi

    python3 -I - "$events" "$run" "$warmup" >> "$OUT_JSONL" <<'PY'
import json, sys
path, run, warmup = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
row = {"run": run, "warmup": warmup}
for line in open(path):
    event = json.loads(line)
    name = event.get("event")
    if name in ("launch_ready", "launch_window_appeared", "engine_ready") and name + "_ms" not in row:
        row[name + "_ms"] = event.get("ms_since_process_start")
print(json.dumps(row, sort_keys=True))
PY
}

launch_once 0 1
for run in $(seq 1 "$RUNS"); do
    launch_once "$run" 0
done
rm -rf -- "$scratch"
