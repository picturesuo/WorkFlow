# WorkFlow quickstart

## Install

### Signed release

Open [WorkFlow Releases](https://github.com/picturesuo/WorkFlow/releases/latest). If a notarized `WorkFlow-…-macOS-arm64.zip` is attached, download it, unzip it, move `WorkFlow.app` to Applications, and open it. Do not bypass Gatekeeper for an unnotarized build.

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

The first build downloads dependencies and can take several minutes. On macOS 26 or newer, the installer can reuse the exact trusted signer from a working WorkFlow or Chat installation. Otherwise, if it reports that no Apple-issued signing identity exists:

1. Open Xcode → Settings → Accounts.
2. Add an Apple Account and select **Manage Certificates**.
3. Create an **Apple Development** certificate.
4. Run `./Scripts/install-local.sh` again.

An agent can handle the terminal steps, but the user should complete Apple-account dialogs and enter API keys personally. See [AGENT_SETUP.md](AGENT_SETUP.md).

## Grant permissions

When WorkFlow opens, allow:

1. **Microphone** — records speech locally.
2. **Accessibility** — pastes into the app that was focused when recording began.
3. **Input Monitoring** — detects the global `Fn`/globe key.

If a prompt is missed, open System Settings → Privacy & Security and enable WorkFlow in those three sections. Quit and reopen WorkFlow after changing Input Monitoring.

## First dictation

1. Wait for Parakeet v3's first model download to finish.
2. Choose **Homework**, **Technical**, or **Everyday** in the main window or WorkFlow's menu-bar menu.
3. Put the cursor in any text field.
4. Hold the bottom-left `Fn`/globe key and speak.
5. Release `Fn` and leave focus in the same app until text appears.

Use Homework for developed prose, Technical for compact commands sent to computers or coding agents, and Everyday for natural messages. After using more than one mode, open **Settings → Cleanup → Writing efficiency this month** to compare their estimated source-to-final token ratios. History also labels each successfully cleaned dictation with its mode and estimated efficiency.

WorkFlow launches at login and stays available in the menu bar by default. Dictation works entirely locally before any API is configured.

## Optional Bedrock cleanup

1. Create a scoped key in the [Bedrock API keys console](https://console.aws.amazon.com/bedrock/home#/api-keys).
2. Open WorkFlow → Settings → Cleanup.
3. Choose **Amazon Bedrock** and paste the key into the secure field.
4. Select **Save & Test**. A successful test shows input/output tokens and its estimated cost.
5. Keep Nova Micro, the three-second fallback, and the default $0.25 monthly stop for the lowest-cost setup.

At the August 21, 2026 US price, a typical 200-input/40-output-token cleanup is about $0.0000126, and 100 daily dictations are about $0.04/month. AWS billing is authoritative.

## If `Fn` does nothing

- Confirm WorkFlow is running in the menu bar.
- Re-enable WorkFlow under System Settings → Privacy & Security → Input Monitoring.
- In WorkFlow → Settings → Shortcuts, confirm `Fn` and hold-to-record are enabled.
- Quit and reopen WorkFlow after permission changes.

If text is copied but not pasted, re-enable Accessibility. The newest transcript remains on the clipboard by default, so Command-V is a safe fallback.
