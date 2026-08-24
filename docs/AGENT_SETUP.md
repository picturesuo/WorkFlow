# Agent setup runbook

This runbook lets a local coding agent install and verify WorkFlow without receiving or printing the user's secrets.

## Security boundary

- Never ask the user to paste an AWS or other provider key into chat, a terminal command, an environment variable, a source file, or a GitHub secret for normal app use.
- Never read or print WorkFlow Keychain items.
- The agent may navigate to WorkFlow's Cleanup settings; the user types the key into the secure field and selects **Save & Test**.
- Apple-account, Keychain, Microphone, Accessibility, and Input Monitoring dialogs remain user-confirmed steps.

## Agent procedure

1. Verify the machine is Apple Silicon with macOS 14 or newer and that `git`, `xcodebuild`, and Homebrew are available.
2. Clone with submodules and install build dependencies:

   ```bash
   git clone --recurse-submodules https://github.com/picturesuo/WorkFlow.git
   cd WorkFlow
   brew install cmake libomp rust
   ```

3. Run the focused deterministic tests before installation:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   xcodebuild test \
     -scheme OpenSuperWhisper \
     -derivedDataPath build \
     -destination 'platform=macOS,arch=arm64' \
     CODE_SIGNING_ALLOWED=NO \
     -only-testing:OpenSuperWhisperTests/RenamedAppMigrationTests \
     -only-testing:OpenSuperWhisperTests/LatestDictationGateTests \
     -only-testing:OpenSuperWhisperTests/ClipboardRestoreTests \
     -only-testing:OpenSuperWhisperTests/OnboardingShortcutOptionTests \
     -only-testing:OpenSuperWhisperTests/EscapeCancelConfirmationTests \
     -only-testing:OpenSuperWhisperTests/BedrockCleanupServiceTests \
     -only-testing:OpenSuperWhisperTests/ProviderPipelineTests
   ```

4. Generate the supplied independent purple icon and install:

   ```bash
   ./Scripts/generate-icon.sh
   ./Scripts/install-local.sh
   open /Applications/WorkFlow.app
   ```

5. On macOS 26 or newer, the installer may reuse the exact trusted signer from a working WorkFlow or earlier Chat installation. If it reports no acceptable identity, direct the user to Xcode → Settings → Accounts → Manage Certificates → `+` → Apple Development. Retry only after the user completes that step.
6. Ask the user to approve WorkFlow under Microphone and Accessibility. Input Monitoring is also required when the user selects `Fn` or another single-modifier shortcut. Upgrades must re-grant these permissions because macOS ties them to the old app identity. Do not automate privacy approval.
7. Verify `WorkFlow.app` is running, its visible version is current, and its bundle identifier is `com.picturesuo.WorkFlow`. For an upgrade, confirm preferences and History were copied from the legacy identity; never delete the legacy data automatically.
8. Have the user perform one short dictation with their selected shortcut in a disposable text field. Confirm the newest spoken text appears and History contains the same result.
9. Set **Technical** in the WorkFlow menu-bar menu and have the user dictate a verbose technical request. Confirm History labels it Technical and shows a source-to-final token estimate. Repeat with Homework only when the user wants to validate long-form behavior; do not fabricate samples in their History.
10. For Bedrock, open Cleanup settings, let the user enter the key, then let the user choose **Save & Test**. Confirm a successful status with token counts. Leave the key field blank in all captured logs and screenshots.

## Definition of done

- `/Applications/WorkFlow.app` launches and remains available in the menu bar.
- The app has Microphone and Accessibility permissions, plus Input Monitoring when a single-modifier shortcut is selected.
- A short hold/release with the selected shortcut produces the newest transcript in the original target.
- The same transcript appears in History and remains available on the clipboard.
- Writing mode is selectable from the main window and menu bar; successful cleanups record mode-specific efficiency without mixing in failed fallbacks.
- If remote cleanup is requested, the in-app connection test passes and the $0.25 monthly estimated-cost stop is enabled.
- No credential appears in shell history, process arguments, source control, logs, or agent conversation.
