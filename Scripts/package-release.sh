#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
version=${1:-}
signing_identity=${CHAT_SIGNING_IDENTITY:-}
notary_profile=${CHAT_NOTARY_PROFILE:-}

if [[ -z "$version" ]]; then
    echo "Usage: CHAT_SIGNING_IDENTITY='Developer ID Application: …' CHAT_NOTARY_PROFILE=… $0 VERSION" >&2
    exit 1
fi

if [[ -z "$signing_identity" || -z "$notary_profile" ]]; then
    echo "CHAT_SIGNING_IDENTITY and CHAT_NOTARY_PROFILE are required." >&2
    exit 1
fi

identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
identity_line=$(print -r -- "$identities" | grep -F -- "$signing_identity" || true)
if [[ "$identity_line" != *"Developer ID Application:"* ]]; then
    echo "Public releases require a Developer ID Application certificate." >&2
    exit 1
fi

cd "$repo_root"
CHAT_BUILD_CONFIGURATION=Release ./run.sh build

source_app="$repo_root/build/Build/Products/Release/Chat.app"
if [[ ! -d "$source_app" ]]; then
    echo "Build succeeded but Chat.app was not found." >&2
    exit 1
fi

release_stage=$(mktemp -d /tmp/chat-release.XXXXXX)
cleanup() {
    if [[ "$release_stage" == /tmp/chat-release.* && -d "$release_stage" ]]; then
        rm -rf -- "$release_stage"
    fi
}
trap cleanup EXIT

staged_app="$release_stage/Chat.app"
submission_zip="$release_stage/Chat-$version-submission.zip"
output_dir="$repo_root/dist"
output_zip="$output_dir/Chat-$version-macOS-arm64.zip"

ditto "$source_app" "$staged_app"
xattr -cr "$staged_app"
codesign --force --deep --options runtime --timestamp \
    --entitlements "$repo_root/OpenSuperWhisper/OpenSuperWhisper.entitlements" \
    --sign "$signing_identity" "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

ditto -c -k --keepParent "$staged_app" "$submission_zip"
xcrun notarytool submit "$submission_zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$staged_app"
xcrun stapler validate "$staged_app"
spctl --assess --type execute --verbose=4 "$staged_app"

mkdir -p "$output_dir"
ditto -c -k --keepParent "$staged_app" "$output_zip"

echo "Created notarized release: $output_zip"
