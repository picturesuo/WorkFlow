#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
source_app="$repo_root/build/Build/Products/Release/WorkFlow.app"
destination_app="/Applications/WorkFlow.app"
previous_app="/Applications/Chat.app"
legacy_app="/Applications/GlowScribe.app"
entitlements_file="$repo_root/OpenSuperWhisper/OpenSuperWhisper.entitlements"
macos_major=${$(sw_vers -productVersion)%%.*}

signing_identity=${WORKFLOW_SIGNING_IDENTITY:-${CHAT_SIGNING_IDENTITY:-}}
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(print -r -- "$identities" \
        | sed -nE '/"(Apple Development|Developer ID Application|Apple Distribution|Mac Developer):/ {
            s/^[[:space:]]*[0-9]+\) ([A-F0-9]+) .*/\1/p
            q
        }')
fi

# A previously working install may use a locally trusted certificate whose
# name does not mimic an Apple certificate. Reusing that exact signer and the
# existing bundle identifier preserves its TCC designated requirement.
reuses_previous_identity=false
signing_sources=("$destination_app" "$previous_app")
if [[ -z "$signing_identity" ]]; then
    for signing_source in "${signing_sources[@]}"; do
        [[ -d "$signing_source" ]] || continue
        previous_authority=$(codesign -dv --verbose=4 "$signing_source" 2>&1 \
            | sed -n 's/^Authority=//p' | head -n 1)
        [[ -n "$previous_authority" ]] || continue
        previous_identity_line=$(print -r -- "$identities" | grep -F -- "\"$previous_authority\"" || true)
        signing_identity=$(print -r -- "$previous_identity_line" \
            | sed -nE 's/^[[:space:]]*[0-9]+\) ([A-F0-9]+) .*/\1/p')
        if [[ -n "$signing_identity" ]]; then
            reuses_previous_identity=true
            break
        fi
    done
fi

# Tahoe silently refuses microphone prompts for ad-hoc or locally self-signed
# apps. Stop before replacing a working install with an app that cannot record.
if (( macos_major >= 26 )); then
    identity_line=$(print -r -- "$identities" | grep -F "$signing_identity" || true)
    if [[ -z "$signing_identity" \
        || ( ! "$identity_line" =~ '"(Apple Development|Developer ID Application|Apple Distribution|Mac Developer):' \
            && "$reuses_previous_identity" != true ) ]]; then
        echo "WorkFlow needs an Apple-issued code-signing identity on macOS 26 or later." >&2
        echo "Open Xcode > Settings > Accounts, add your Apple Account, and create an Apple Development certificate." >&2
        echo "Then rerun this installer (or set WORKFLOW_SIGNING_IDENTITY explicitly)." >&2
        exit 1
    fi
fi

cd "$repo_root"
WORKFLOW_BUILD_CONFIGURATION=Release ./run.sh build

if [[ ! -d "$source_app" ]]; then
    echo "Build succeeded but WorkFlow.app was not found." >&2
    exit 1
fi

install_stage=$(mktemp -d /tmp/workflow-install.XXXXXX)
cleanup() {
    if [[ "$install_stage" == /tmp/workflow-install.* && -d "$install_stage" ]]; then
        rm -rf -- "$install_stage"
    fi
}
trap cleanup EXIT

staged_app="$install_stage/WorkFlow.app"
ditto "$source_app" "$staged_app"
xattr -cr "$staged_app"

if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
fi

# Sign nested code first, then the app itself with the permissions macOS uses
# to identify microphone, Accessibility, and Input Monitoring grants.
codesign --force --deep --sign "$signing_identity" --timestamp=none --options runtime \
    "$staged_app"
codesign --force --sign "$signing_identity" --timestamp=none --options runtime \
    --entitlements "$entitlements_file" "$staged_app"
codesign --verify --deep --strict "$staged_app"

pkill -f -x "$destination_app/Contents/MacOS/WorkFlow" 2>/dev/null || true
pkill -f -x "$previous_app/Contents/MacOS/Chat" 2>/dev/null || true
pkill -f -x "$legacy_app/Contents/MacOS/GlowScribe" 2>/dev/null || true

old_apps=("$destination_app" "$previous_app" "$legacy_app")
for old_app in "${old_apps[@]}"; do
    if [[ -d "$old_app" ]]; then
        old_name=${old_app:t:r}
        legacy_archive="$HOME/.Trash/$old_name-$(date +%Y%m%d-%H%M%S).app"
        mv "$old_app" "$legacy_archive"
        echo "Moved the previous app to $legacy_archive"
    fi
done

ditto "$staged_app" "$destination_app"
codesign --verify --deep --strict "$destination_app"

echo "Installed $destination_app (signing identity: $signing_identity)"
