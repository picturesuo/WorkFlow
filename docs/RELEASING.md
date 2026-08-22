# Releasing Chat

Chat must be distributed outside the Mac App Store because system-wide hotkeys and targeted paste require Accessibility and event-monitoring capabilities that are incompatible with the App Sandbox.

Public binaries must be signed with a paid Apple Developer Program **Developer ID Application** certificate and notarized. Do not publish an ad-hoc, self-signed, or Apple Development build: macOS may reject its microphone permission or show an unsafe-app warning.

## One-time maintainer setup

1. Install a Developer ID Application certificate in the login keychain.
2. Store App Store Connect credentials for `notarytool`:

   ```bash
   xcrun notarytool store-credentials chat-notary \
     --apple-id YOUR_APPLE_ID \
     --team-id YOUR_TEAM_ID
   ```

   Enter an app-specific password when prompted. Do not put the password, exported certificate, or AWS key in this repository.

## Build and notarize

Run the full tests first, then package a release:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -scheme OpenSuperWhisper \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO

CHAT_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
CHAT_NOTARY_PROFILE=chat-notary \
./Scripts/package-release.sh 0.3.0
```

The script fails closed unless the configured identity is a Developer ID Application certificate and the requested version matches the built app. It builds Release, enables the hardened runtime, signs nested code, submits the archive to Apple, staples the ticket, runs Gatekeeper assessment, and writes `dist/Chat-VERSION-macOS-arm64.zip`.

Test that archive on a second Mac before creating a GitHub release. Verify launch, first-run Microphone/Accessibility/Input Monitoring prompts, Fn hold-to-record, each supported cleanup provider and fallback, targeted paste, vocabulary, per-app rules, meeting recording, history, and launch at login.

## GitHub Actions release

The **Notarized Release** workflow runs manually or from a `v*` tag. It fails before building if any required secret is missing and publishes a GitHub release only for a pushed tag.

Configure these repository secrets:

- `MACOS_SIGNING_IDENTITY`: full Developer ID Application identity name
- `MACOS_CERTIFICATE_P12_BASE64`: base64-encoded exported Developer ID certificate and private key
- `MACOS_CERTIFICATE_PASSWORD`: export password for that `.p12`
- `MACOS_KEYCHAIN_PASSWORD`: an ephemeral CI keychain password
- `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`: notarization credentials

The workflow imports the certificate into a temporary runner keychain, runs the deterministic headless-safe test set used by the build workflow, delegates signing/notarization/Gatekeeper verification to the same fail-closed packaging script used locally, and uploads only the resulting notarized zip. GitHub secrets are never copied into the app bundle or release artifact.

## Publish

Use a version tag matching the app version. Review the release notes for private information before publishing them and attach only the notarized archive:

```bash
gh release create v0.3.0 dist/Chat-0.3.0-macOS-arm64.zip --generate-notes
```
