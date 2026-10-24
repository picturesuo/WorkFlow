# WorkFlow quickstart

## Install

### Public release status

The current v0.5.1 release contains source archives only. A notarized `WorkFlow-…-macOS-arm64.zip` is not attached yet, so use the local source build below. Do not bypass Gatekeeper for an unsigned or unnotarized build. Future signed builds will appear on [WorkFlow Releases](https://github.com/picturesuo/WorkFlow/releases/latest).

### Local source build

On an Apple Silicon Mac with macOS 14 or newer:

```bash
git clone --recurse-submodules https://github.com/picturesuo/WorkFlow.git
cd WorkFlow
brew install cmake libomp rust
./Scripts/install-local.sh
open /Applications/WorkFlow.app
```

The first build downloads dependencies and can take several minutes. WorkFlow now uses its own `com.picturesuo.WorkFlow` identity. When upgrading from Chat or GlowScribe, it copies preferences and History/models forward without deleting the old data and moves provider credentials into WorkFlow's Keychain identity. macOS privacy grants cannot be copied, so approve WorkFlow once under Microphone, Accessibility, and—if selected—Input Monitoring. On macOS 26 or newer, the installer can reuse the exact trusted signer from a working installation. Otherwise, if it reports that no Apple-issued signing identity exists:

1. Open Xcode → Settings → Accounts.
2. Add an Apple Account and select **Manage Certificates**.
3. Create an **Apple Development** certificate.
4. Run `./Scripts/install-local.sh` again.

An agent can handle the terminal steps, but the user should complete Apple-account dialogs and enter API keys personally. See [AGENT_SETUP.md](AGENT_SETUP.md).

## Grant permissions

When WorkFlow opens, allow:

1. **Microphone** — records speech locally.
2. **Accessibility** — pastes into the app that was focused when recording began.
3. **Input Monitoring** — needed only when you choose `Fn`/globe, another single-modifier shortcut, or `Control`+`Fn`.

If a prompt is missed, open System Settings → Privacy & Security and enable the missing permission. WorkFlow detects a newly granted Input Monitoring permission and activates the selected shortcut automatically.

## Settings at a glance

Settings (⌘,) has four panes; ⌘1 to ⌘4 switch between them, and Settings reopens on the pane you last used.

- **Dictation**: the shortcut (and an optional second key, or **Control + Fn (hold both)**, where Fn or Control alone does nothing), whether you hold or tap to record, the speech model, the language, and whether text is pasted and kept on the clipboard. Sounds, Escape, startup, History storage, and Whisper decoding wait under **More options**.
- **Cleanup**: AI cleanup on or off, the four writing modes with an example each, your custom filters, and meeting cleanup.
- **Personalize**: learning from finished writing, personal vocabulary, per-app rules, and a JSON backup.
- **Provider & Cost**: the cleanup provider and its key, the monthly estimated-cost stop, and this month's usage.

## Main window at a glance

- **Toolbar**: search History, start or stop a meeting recording, **More** (⋯) for **Delete All Recordings…**, and Settings.
- **History**: dictations grouped by day, newest first. Each row has **Copy**; its ⋯ menu, or a right-click, also offers Play Recording, Regenerate Transcript, and Delete Recording. A failed transcription that kept its audio shows **Regenerate** in place of Copy, and a long transcript opens with **Show full text**.
- **Dictation bar**: the writing mode and **Learn…**, what dictation is doing now with your shortcut, the microphone menu (⌄), and the record button.

## First dictation

1. In onboarding, keep the permission-free `Option`+backtick shortcut or choose `Fn`/globe and enable Input Monitoring.
2. Download the recommended Parakeet v3 model (about 483 MB). Onboarding shows its percentage and marks it **Ready** when complete.
3. Choose **Homework**, **Technical**, **Everyday**, or a saved custom filter in the main window or WorkFlow's menu-bar menu.
4. Put the cursor in any text field, hold your chosen shortcut, speak, and release it.
5. Keep the cursor in the intended field until text appears. WorkFlow targets the app that was active when recording began, but changing fields inside that app can redirect the paste.

Use Homework for developed prose, Technical for compact commands sent to computers or coding agents, and Everyday for natural messages. After using more than one mode, open **Settings → Provider & Cost → Usage this month** to compare their estimated source-to-final token ratios. History also labels each successfully cleaned dictation with its mode and estimated efficiency.

To make a mode more specific, open **Settings → Cleanup → Custom filters**, choose **New filter**, pick a base mode, and describe the change in plain language, for example "Write all numbers as digits." The filter then appears next to the built-in modes.

WorkFlow launches at login and stays available in the menu bar by default. Dictation works entirely locally before any API is configured.

If you sometimes press Escape accidentally, enable **Settings → Dictation → More options → Ignore Esc while recording**. Escape will then leave active dictations recording; use the configured recording shortcut to finish normally. Escape while a stopped dictation is still transcribing cancels its paste either way; the text stays in History.

## Optional Bedrock cleanup

1. Create a scoped key in the [Bedrock API keys console](https://console.aws.amazon.com/bedrock/home#/api-keys).
2. Open WorkFlow → Settings → **Provider & Cost**.
3. Choose **Amazon Bedrock** as the cleanup provider and paste the key into the secure field.
4. Select **Save & Test**. A successful test shows input/output tokens and its estimated cost.
5. Keep Nova Micro, the three-second timeout, and the default $0.25 monthly stop for the lowest-cost setup. The stop is WorkFlow's estimate, not a billing cap; when it is reached, Bedrock requests pause until next month and dictations keep their original transcript.

Amazon models are available by default in commercial AWS regions when the key has the required Bedrock permissions. If the test reports `AccessDeniedException`, confirm that the key can invoke Nova Micro in `us-east-1`; an organization policy or restricted account may require an administrator to grant model access.

At the August 21, 2026 US price, a typical 200-input/40-output-token cleanup is about $0.0000126, and 100 daily dictations are about $0.04/month. AWS billing is authoritative.

## Optional Azure OpenAI cleanup

1. Deploy a small chat model in [Microsoft Foundry](https://ai.azure.com) and note its deployment name.
2. Open WorkFlow → Settings → **Provider & Cost** and choose **Azure OpenAI**.
3. Enter the resource endpoint, for example `https://YOUR-RESOURCE.openai.azure.com`, and the deployment name.
4. Paste the resource key into the secure field and select **Save & Test**.

Usage bills to your Azure subscription; WorkFlow reports tokens but does not estimate Azure prices.

## If your shortcut does nothing

- Confirm WorkFlow is running in the menu bar.
- If you selected `Fn`, `Control`+`Fn`, or another modifier, enable WorkFlow under System Settings → Privacy & Security → Input Monitoring.
- If the emoji picker, an input source switch, or macOS Dictation also opens with `Control`+`Fn`, set System Settings → Keyboard → Press 🌐 key to **Do Nothing**.
- In WorkFlow → Settings → Dictation, confirm the shortcut and whether it records while you hold it (**Hold**) or between two presses (**Tap**).
- WorkFlow detects a newly granted Input Monitoring permission and activates the shortcut automatically.

If text is copied but not pasted, re-enable Accessibility. The newest transcript remains on the clipboard by default, so Command-V is a safe fallback.
