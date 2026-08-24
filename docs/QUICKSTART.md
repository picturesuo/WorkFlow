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
./Scripts/generate-icon.sh
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
3. **Input Monitoring** — needed only when you choose `Fn`/globe or another single-modifier shortcut.

If a prompt is missed, open System Settings → Privacy & Security and enable the missing permission. WorkFlow detects a newly granted Input Monitoring permission and activates the selected shortcut automatically.

## First dictation

1. In onboarding, keep the permission-free `Option`+backtick shortcut or choose `Fn`/globe and enable Input Monitoring.
2. Download the recommended Parakeet v3 model (about 483 MB). Onboarding shows its percentage and marks it **Ready** when complete.
3. Choose **Homework**, **Technical**, or **Everyday** in the main window or WorkFlow's menu-bar menu.
4. Put the cursor in any text field, hold your chosen shortcut, speak, and release it.
5. Keep the cursor in the intended field until text appears. WorkFlow targets the app that was active when recording began, but changing fields inside that app can redirect the paste.

Use Homework for developed prose, Technical for compact commands sent to computers or coding agents, and Everyday for natural messages. After using more than one mode, open **Settings → Cleanup → Writing efficiency this month** to compare their estimated source-to-final token ratios. History also labels each successfully cleaned dictation with its mode and estimated efficiency.

WorkFlow launches at login and stays available in the menu bar by default. Dictation works entirely locally before any API is configured.

If you sometimes press Escape accidentally, enable **Settings → Shortcuts → Ignore Esc while recording**. Escape will then leave active dictations recording; use the configured recording shortcut to finish normally.

## Optional Bedrock cleanup

1. Create a scoped key in the [Bedrock API keys console](https://console.aws.amazon.com/bedrock/home#/api-keys).
2. Open WorkFlow → Settings → Cleanup.
3. Choose **Amazon Bedrock** and paste the key into the secure field.
4. Select **Save & Test**. A successful test shows input/output tokens and its estimated cost.
5. Keep Nova Micro, the three-second fallback, and the default $0.25 monthly stop for the lowest-cost setup.

At the August 21, 2026 US price, a typical 200-input/40-output-token cleanup is about $0.0000126, and 100 daily dictations are about $0.04/month. AWS billing is authoritative.

## If your shortcut does nothing

- Confirm WorkFlow is running in the menu bar.
- If you selected `Fn` or another modifier, enable WorkFlow under System Settings → Privacy & Security → Input Monitoring.
- In WorkFlow → Settings → Shortcuts, confirm the expected shortcut and hold-to-record are enabled.
- WorkFlow detects a newly granted Input Monitoring permission and activates the shortcut automatically.

If text is copied but not pasted, re-enable Accessibility. The newest transcript remains on the clipboard by default, so Command-V is a safe fallback.
