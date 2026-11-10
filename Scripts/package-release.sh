#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
version=${1:-}
signing_identity=${WORKFLOW_SIGNING_IDENTITY:-${CHAT_SIGNING_IDENTITY:-}}
notary_profile=${WORKFLOW_NOTARY_PROFILE:-${CHAT_NOTARY_PROFILE:-}}

if [[ -z "$version" ]]; then
    echo "Usage: WORKFLOW_SIGNING_IDENTITY='Developer ID Application: …' WORKFLOW_NOTARY_PROFILE=… $0 VERSION" >&2
    exit 1
fi

if [[ -z "$signing_identity" || -z "$notary_profile" ]]; then
    echo "WORKFLOW_SIGNING_IDENTITY and WORKFLOW_NOTARY_PROFILE are required." >&2
    exit 1
fi

identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
identity_line=$(print -r -- "$identities" | grep -F -- "$signing_identity" || true)
if [[ "$identity_line" != *"Developer ID Application:"* ]]; then
    echo "Public releases require a Developer ID Application certificate." >&2
    exit 1
fi

cd "$repo_root"
WORKFLOW_BUILD_CONFIGURATION=Release ./run.sh build

source_app="$repo_root/build/Build/Products/Release/WorkFlow.app"
if [[ ! -d "$source_app" ]]; then
    echo "Build succeeded but WorkFlow.app was not found." >&2
    exit 1
fi

# A shipped build must not carry LLVM code-coverage instrumentation
# (counters on every code region and a .profraw write at exit).
for tool in otool od; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Cannot check the build for coverage instrumentation: $tool is missing." >&2
        exit 1
    fi
done
for candidate in "$source_app"/**/*(ND.); do
    header=$(od -An -tx1 -N8 -- "$candidate" | tr -d ' \n')
    case "${header[1,8]}" in
        feedface|feedfacf|cefaedfe|cffaedfe) ;;
        cafebabe|cafebabf)
            # A fat Mach-O lists a handful of architectures here; a Java
            # class file has its version (45 or more) in the same bytes.
            if (( ${#header} < 16 || 16#${header[9,16]} > 30 )); then continue; fi
            ;;
        *) continue ;;
    esac
    if ! load_commands=$(otool -l "$candidate" 2>&1); then
        echo "Cannot inspect $candidate for coverage instrumentation." >&2
        exit 1
    fi
    if [[ "$load_commands" == *"sectname __llvm_prf_cnts"* ]]; then
        echo "Release build is instrumented for code coverage: $candidate" >&2
        exit 1
    fi
done

app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")
if [[ "$app_version" != "$version" ]]; then
    echo "Requested release $version does not match app version $app_version." >&2
    exit 1
fi

release_stage=$(mktemp -d /tmp/workflow-release.XXXXXX)
cleanup() {
    if [[ "$release_stage" == /tmp/workflow-release.* && -d "$release_stage" ]]; then
        rm -rf -- "$release_stage"
    fi
}
trap cleanup EXIT

staged_app="$release_stage/WorkFlow.app"
submission_zip="$release_stage/WorkFlow-$version-submission.zip"
output_dir="$repo_root/dist"
output_zip="$output_dir/WorkFlow-$version-macOS-arm64.zip"

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
