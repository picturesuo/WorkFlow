#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
source_app="$repo_root/build/Build/Products/Release/GlowScribe.app"
destination_app="/Applications/GlowScribe.app"
entitlements_file="$repo_root/OpenSuperWhisper/OpenSuperWhisper.entitlements"
macos_major=${$(sw_vers -productVersion)%%.*}

signing_identity=${GLOWSCRIBE_SIGNING_IDENTITY:-}
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(print -r -- "$identities" \
        | sed -nE '/"(Apple Development|Developer ID Application|Apple Distribution|Mac Developer):/ {
            s/^[[:space:]]*[0-9]+\) ([A-F0-9]+) .*/\1/p
            q
        }')
fi

# Tahoe silently refuses microphone prompts for ad-hoc or locally self-signed
# apps. Stop before replacing a working install with an app that cannot record.
if (( macos_major >= 26 )); then
    identity_line=$(print -r -- "$identities" | grep -F "$signing_identity" || true)
    if [[ -z "$signing_identity" \
        || ! "$identity_line" =~ '"(Apple Development|Developer ID Application|Apple Distribution|Mac Developer):' ]]; then
        echo "GlowScribe needs an Apple-issued code-signing identity on macOS 26 or later." >&2
        echo "Open Xcode > Settings > Accounts, add your Apple Account, and create an Apple Development certificate." >&2
        echo "Then rerun this installer (or set GLOWSCRIBE_SIGNING_IDENTITY explicitly)." >&2
        exit 1
    fi
fi

cd "$repo_root"
GLOWSCRIBE_BUILD_CONFIGURATION=Release ./run.sh build

if [[ ! -d "$source_app" ]]; then
    echo "Build succeeded but GlowScribe.app was not found." >&2
    exit 1
fi

if pgrep -x GlowScribe >/dev/null 2>&1; then
    pkill -x GlowScribe
fi

ditto "$source_app" "$destination_app"
xattr -cr "$destination_app"

if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
fi

# Sign nested code first, then the app itself with the permissions macOS uses
# to identify microphone, Accessibility, and Input Monitoring grants.
codesign --force --deep --sign "$signing_identity" --timestamp=none --options runtime \
    "$destination_app"
codesign --force --sign "$signing_identity" --timestamp=none --options runtime \
    --entitlements "$entitlements_file" "$destination_app"
codesign --verify --deep --strict "$destination_app"

echo "Installed $destination_app (signing identity: $signing_identity)"
