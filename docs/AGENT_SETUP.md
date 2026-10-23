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

3. Run the focused deterministic tests before installation. The test host runs under its own bundle identifier, so the tests never read or change WorkFlow's preferences:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   xcodebuild test \
     -scheme OpenSuperWhisper \
     -derivedDataPath build \
     -destination 'platform=macOS,arch=arm64' \
     CODE_SIGNING_ALLOWED=NO \
     PRODUCT_BUNDLE_IDENTIFIER=com.picturesuo.WorkFlow.fmtest \
     -only-testing:OpenSuperWhisperTests/RenamedAppMigrationTests \
     -only-testing:OpenSuperWhisperTests/LatestDictationGateTests \
     -only-testing:OpenSuperWhisperTests/LatestDictationDeliveryTests \
     -only-testing:OpenSuperWhisperTests/DictationFailureRecoveryTests \
     -only-testing:OpenSuperWhisperTests/QueuedAudioRetentionTests \
     -only-testing:OpenSuperWhisperTests/SettingsRequestTests \
     -only-testing:OpenSuperWhisperTests/ClipboardRestoreTests \
     -only-testing:OpenSuperWhisperTests/OnboardingShortcutOptionTests \
     -only-testing:OpenSuperWhisperTests/EscapeCancelConfirmationTests \
     -only-testing:OpenSuperWhisperTests/BedrockCleanupServiceTests \
     -only-testing:OpenSuperWhisperTests/ProviderPipelineTests \
     -only-testing:OpenSuperWhisperTests/CustomCleanupFilterStoreTests \
     -only-testing:OpenSuperWhisperTests/CustomCleanupPromptTests \
     -only-testing:OpenSuperWhisperTests/CustomFilterNumberGuardTests \
     -only-testing:OpenSuperWhisperTests/CustomFilterPipelineTests \
     -only-testing:OpenSuperWhisperTests/CustomFilterProviderTransportTests \
     -only-testing:OpenSuperWhisperTests/FilterAssistantPromptTests \
     -only-testing:OpenSuperWhisperTests/FilterAssistantTransportTests \
     -only-testing:OpenSuperWhisperTests/FilterAssistantSessionTests \
     -only-testing:OpenSuperWhisperTests/FilterAssistantMathCleanupTests \
     -only-testing:OpenSuperWhisperTests/FilterAssistantVoiceInputTests \
     -only-testing:OpenSuperWhisperTests/FilterAssistantLayoutTests \
     -only-testing:OpenSuperWhisperTests/BrandPaletteTests \
     -only-testing:OpenSuperWhisperTests/BrandLayoutTests \
     -only-testing:OpenSuperWhisperTests/MeaningPreservationGuardTests \
     -only-testing:OpenSuperWhisperTests/CleanupReplyCompletenessTransportTests \
     -only-testing:OpenSuperWhisperTests/RecognizerToCleanupTraceTests \
     -only-testing:OpenSuperWhisperTests/CustomFilterHistoryTests \
     -only-testing:OpenSuperWhisperTests/NumericPreservationGuardTests \
     -only-testing:OpenSuperWhisperTests/DictationSourceEvidenceTests \
     -only-testing:OpenSuperWhisperTests/CorrectionAlignerTests \
     -only-testing:OpenSuperWhisperTests/CorrectionPreferenceValidationTests \
     -only-testing:OpenSuperWhisperTests/LearnedPreferenceStoreTests \
     -only-testing:OpenSuperWhisperTests/LearnedPreferenceScopeTests \
     -only-testing:OpenSuperWhisperTests/CorrectionLearningSessionTests \
     -only-testing:OpenSuperWhisperTests/CorrectionLearningLayoutTests \
     -only-testing:OpenSuperWhisperTests/DocumentTextExtractorTests \
     -only-testing:OpenSuperWhisperTests/DocumentTypeLookupTests \
     -only-testing:OpenSuperWhisperTests/CoreAudioDeviceLookupTests \
     -only-testing:OpenSuperWhisperTests/WhisperConversionFingerprintTests \
     -only-testing:OpenSuperWhisperTests/WhisperProgressCallbackTests \
     -only-testing:OpenSuperWhisperTests/DictationLearningFlowTests
   ```

   `RecognizerToCleanupTraceTests` skips itself unless the Parakeet v3 model is already cached. `DictationLearningFlowTests` uses scripted stand-ins for the recognizer and providers, so it proves the dictation-to-learning plumbing, not real provider quality.

4. Install the app. The WorkFlow ivory ribbon icon is already included in the repository:

   ```bash
   ./Scripts/install-local.sh
   open /Applications/WorkFlow.app
   ```

5. On macOS 26 or newer, the installer may reuse the exact trusted signer from a working WorkFlow or earlier Chat installation. If it reports no acceptable identity, direct the user to Xcode → Settings → Accounts → Manage Certificates → `+` → Apple Development. Retry only after the user completes that step.
6. Ask the user to approve WorkFlow under Microphone and Accessibility. Input Monitoring is also required when the user selects `Fn` or another single-modifier shortcut. Upgrades must re-grant these permissions because macOS ties them to the old app identity. Do not automate privacy approval.
7. Verify `WorkFlow.app` is running, its visible version is current, and its bundle identifier is `com.picturesuo.WorkFlow`. For an upgrade, confirm preferences and History were copied from the legacy identity; never delete the legacy data automatically.
8. Have the user perform one short dictation with their selected shortcut in a disposable text field. Confirm the newest spoken text appears and History contains the same result.
9. Set **Technical** in the WorkFlow menu-bar menu and have the user dictate a verbose technical request. Confirm History labels it Technical and shows a source-to-final token estimate. Repeat with Homework only when the user wants to validate long-form behavior; do not fabricate samples in their History.
10. For Bedrock or Azure OpenAI, open Cleanup settings, let the user enter the key, then let the user choose **Save & Test**. For Azure, the user also enters the resource endpoint and deployment name. Confirm a successful status with token counts. Leave the key field blank in all captured logs and screenshots.
11. To verify Writing mode or learning, let the user select **Writing** (or another mode), dictate into a disposable document, edit it, then paste the whole finished document under **Settings → Personalize → Learn from finished writing** (also reached from **Learn…** beside the writing mode in the main window) and select **Learn**. Confirm the outcome names the matched dictations and the learned preferences listed for that mode. Do not fabricate samples in their History.
12. To verify custom filters, let the user create one under **Settings → Cleanup → Custom filters** (for example **Everyday with digits**), select it in the menu-bar menu, and dictate a sentence with a spoken number. Confirm History labels the result with the filter name. Do not fabricate samples in their History. To verify AI drafting, let the user choose **Create with AI**, type or speak a request (and optionally paste a finished example), press **Send**, review the proposal, and save it.

## Definition of done

- `/Applications/WorkFlow.app` launches and remains available in the menu bar.
- The app has Microphone and Accessibility permissions, plus Input Monitoring when a single-modifier shortcut is selected.
- A short hold/release with the selected shortcut produces the newest transcript in the original target.
- The same transcript appears in History and remains available on the clipboard.
- Writing mode is selectable from the main window and menu bar; successful cleanups record mode-specific efficiency without mixing in failed fallbacks.
- If remote cleanup is requested, the in-app connection test passes and the $0.25 monthly estimated-cost stop is enabled.
- No credential appears in shell history, process arguments, source control, logs, or agent conversation.
