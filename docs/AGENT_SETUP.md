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
     -only-testing:OpenSuperWhisperTests/LatestDictationGateTests \
     -only-testing:OpenSuperWhisperTests/ClipboardRestoreTests \
     -only-testing:OpenSuperWhisperTests/BedrockCleanupServiceTests \
     -only-testing:OpenSuperWhisperTests/ProviderPipelineTests
   ```

4. Generate the supplied independent purple icon and install:

   ```bash
   ./Scripts/generate-icon.sh
   ./Scripts/install-local.sh
   open /Applications/WorkFlow.app
   ```

5. On macOS 26 or newer, the installer may reuse the exact trusted signer from a working WorkFlow or Chat installation. If it instead reports no acceptable identity, direct the user to Xcode → Settings → Accounts → Manage Certificates → `+` → Apple Development. Retry only after the user completes that step.
6. Ask the user to approve WorkFlow under Microphone, Accessibility, and Input Monitoring. Do not automate privacy approval.
7. Verify `WorkFlow.app` is running, its visible version is current, and its bundle identifier is `com.picturesuo.Chat`. That identifier is intentionally retained to preserve existing local permissions, history, preferences, and Keychain data.
8. Have the user perform one short `Fn` dictation into a disposable text field. Confirm the newest spoken text appears and History contains the same result.
9. For Bedrock, open Cleanup settings, let the user enter the key, then let the user choose **Save & Test**. Confirm a successful status with token counts. Leave the key field blank in all captured logs and screenshots.

## Definition of done

- `/Applications/WorkFlow.app` launches and remains available in the menu bar.
- The app has all three required macOS permissions.
- A short `Fn` hold/release produces the newest transcript in the original target.
- The same transcript appears in History and remains available on the clipboard.
- If remote cleanup is requested, the in-app connection test passes and the $0.25 monthly estimated-cost stop is enabled.
- No credential appears in shell history, process arguments, source control, logs, or agent conversation.
