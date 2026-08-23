# Releasing WorkFlow

This is the canonical release procedure. WorkFlow is distributed outside the Mac App Store because global `Fn` monitoring and targeted paste require capabilities that do not fit its sandbox model.

Public binaries must be signed with a paid Apple Developer Program **Developer ID Application** certificate and notarized. Never publish an ad-hoc, self-signed, or Apple Development build: macOS may reject its microphone permission or warn users that it is unsafe.

## One-time maintainer setup

1. Install a Developer ID Application certificate in the login keychain.
2. Store App Store Connect credentials:

   ```bash
   xcrun notarytool store-credentials workflow-notary \
     --apple-id YOUR_APPLE_ID \
     --team-id YOUR_TEAM_ID
   ```

   Enter the app-specific password at the prompt. Never put that password, an exported certificate, or a provider API key in this repository.

## Build and notarize

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -scheme OpenSuperWhisper \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO

WORKFLOW_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
WORKFLOW_NOTARY_PROFILE=workflow-notary \
./Scripts/package-release.sh 0.5.0
```

The packaging script verifies the certificate type and app version, builds Release, enables hardened runtime, signs nested code, submits to Apple, staples the ticket, runs Gatekeeper assessment, and writes `dist/WorkFlow-VERSION-macOS-arm64.zip`. The legacy `CHAT_SIGNING_IDENTITY` and `CHAT_NOTARY_PROFILE` aliases remain accepted only for migration during the 0.x series.

Test the archive on a second Mac. Verify first-run permissions, a short and a rapid back-to-back `Fn` dictation, Bedrock and local fallback, targeted paste, clipboard fallback, vocabulary, per-app rules, meeting recording, History, VoiceOver labels, and launch at login.

## GitHub Actions

The **Notarized Release** workflow runs manually or from a `v*` tag after the repository variable `ENABLE_NOTARIZED_RELEASES` is set to `true`. Without that variable, the notarized-binary job is safely skipped so source-only releases do not create a failing build. Once enabled, the job fails before building when a required secret is missing and publishes the binary only for a pushed tag.

Configure:

- `MACOS_SIGNING_IDENTITY`
- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

The workflow imports the certificate into an ephemeral keychain and delegates packaging to the same fail-closed script used locally. Secrets are not copied into the app or artifact.

## Publish

Review public release text for private information, then use the version tag that matches the app:

```bash
gh release create v0.5.0 dist/WorkFlow-0.5.0-macOS-arm64.zip --generate-notes
```

After publication, confirm that [the latest-release page](https://github.com/picturesuo/WorkFlow/releases/latest) serves the notarized archive and that a clean Mac accepts it without bypassing Gatekeeper.
