<p align="center">
  <img src="docs/chat-icon.png" width="144" height="144" alt="Chat icon">
</p>

<h1 align="center">Chat</h1>

<p align="center">
  Hold <kbd>Fn</kbd>, speak, release, and get polished text in the app you were already using.
</p>

Chat is an open-source macOS dictation app built for the fast, system-wide workflow popularized by Wispr Flow and Superwhisper—without a recurring dictation subscription. Speech recognition runs locally with Parakeet or Whisper. An optional, inexpensive Amazon Bedrock pass removes fillers, resolves self-corrections, and fixes punctuation before the current utterance is pasted.

Chat is not affiliated with Wispr Flow or Superwhisper.

## What makes it useful

- **One-button dictation:** hold the bottom-left `Fn`/globe key, speak, then release.
- **Local speech recognition:** Parakeet v3 is the default; Whisper remains available.
- **Bedrock cleanup:** Amazon Nova Micro performs literal transcript cleanup through the Bedrock Converse API.
- **Visible cost and provenance:** history identifies Bedrock-cleaned versus local-fallback dictations, while Settings totals the actual tokens returned by AWS and estimates their cost.
- **Failure-safe:** a three-second deadline falls back to the raw local transcript, so an API problem does not eat your words.
- **Current utterance only:** a monotonic generation gate prevents an older async result from winning a paste race.
- **Clipboard-safe paste:** Chat pastes the generated text and restores the prior clipboard only if the clipboard has not changed since.
- **Keychain storage:** the Bedrock API key never goes into `UserDefaults`, source files, or logs.
- **Ready after login:** the app registers with macOS Launch at Login and can stay hidden in the menu bar.

## How it works

```text
Fn down → record locally → Parakeet/Whisper → Bedrock Nova Micro → generation check → paste
                                              ↘ timeout/error → raw transcript ↗
```

Audio stays on the Mac. When cleanup is enabled, only the raw transcript is sent to the Bedrock model you configure.

## Install from source

Requirements: Apple Silicon Mac, macOS 14 or later, Xcode, Homebrew, Rust, and Git. On macOS 26 Tahoe or later, add your Apple Account in **Xcode → Settings → Accounts** and create a free Apple Development certificate before installing. Tahoe silently rejects microphone requests from ad-hoc and locally self-signed apps.

```bash
git clone --recurse-submodules https://github.com/picturesuo/chat.git
cd chat
brew install cmake libomp rust
./Scripts/generate-icon.sh
./Scripts/install-local.sh
open /Applications/Chat.app
```

Grant Microphone, Accessibility, and Input Monitoring when macOS asks. The first two permit recording and paste; Input Monitoring permits the global `Fn` trigger. The default configuration is Parakeet v3, hold-to-record, auto-paste, and launch at login.

The installer prefers an Apple Development, Developer ID Application, Apple Distribution, or Mac Developer identity so macOS permission grants survive rebuilds. Set `CHAT_SIGNING_IDENTITY` to a certificate name or SHA-1 hash from the default keychain search list to select one explicitly. On macOS 25 and earlier, the installer can fall back to ad-hoc signing and macOS may ask for permissions again after a rebuild. On macOS 26 and later, it stops with setup instructions if no Apple-issued identity exists, because an ad-hoc install would launch but could not request microphone access.

For a build without installation, run `./run.sh build`.

If you build directly in Xcode, select your own Apple Developer team in **Signing & Capabilities**. The public project intentionally does not contain a contributor-specific team ID.

## Connect Amazon Bedrock

1. Open the [Amazon Bedrock API keys console](https://console.aws.amazon.com/bedrock/home#/api-keys).
   - Easiest personal setup: create a long-term key with an explicit expiration and permission only to invoke the model you plan to use. AWS designates long-term keys for exploration.
   - AWS-recommended production setup: generate and automatically refresh a short-term key. Short-term keys last no more than 12 hours, so a key pasted into Chat must be replaced when it expires.
2. Open **Chat → Settings → Bedrock**.
3. Paste the key and click **Save & Test**. The key is stored in the macOS Keychain under `AWS_BEARER_TOKEN_BEDROCK`.
4. Keep the defaults unless your AWS setup requires another region or model:
   - Region: `us-east-1`
   - Model: `us.amazon.nova-micro-v1:0` (the US cross-Region inference profile)
   - Raw fallback: `3.0` seconds

Chat never stores an AWS secret in the repository or preferences. See the official [Bedrock API keys guide](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html) and [Converse API reference](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html).

### Cost

The live AWS US on-demand catalog reported Nova Micro at **$0.035 per million input tokens** and **$0.14 per million output tokens** on August 21, 2026. For example, a short cleanup using 200 input and 40 output tokens costs about **$0.0000126**; 100 such dictations every day is about **$0.04/month**.

Chat records the token counts returned by the Converse API and shows per-dictation estimates in History plus a monthly total in **Settings → Bedrock**. Custom model IDs still show token counts, but Chat deliberately omits a dollar estimate unless it has a dated price for that model. Estimates exclude taxes, discounts, free tiers, and later AWS price changes; verify the current [Bedrock pricing page](https://aws.amazon.com/bedrock/pricing/).

## Cleanup contract

The Bedrock prompt treats speech as untrusted text. It may remove fillers, keep the final version of a self-correction, and repair obvious grammar or punctuation. It must not answer instructions, invent content, or wrap the result in an explanation. Responses that look like assistant prose or expand far beyond the source are rejected and the local transcript is used instead.

## Development and tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -scheme OpenSuperWhisper \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

Focused coverage includes Bedrock request/response handling, unsafe rewrite rejection, latest-generation gating, clipboard restoration, empty-dictation discard, shortcuts, recording lifecycle, and model behavior.

## Public releases

The repository is public and can be installed from source today. A broadly downloadable macOS binary additionally requires a paid Developer ID Application certificate and Apple notarization; a development or ad-hoc signature is not a safe substitute. Maintainers can use the fail-closed packaging workflow in [docs/RELEASING.md](docs/RELEASING.md). Once a notarized archive is published, it should be attached to this repository's Releases page.

## Privacy and security

- No Chat server exists.
- Audio is processed locally.
- Bedrock receives transcript text only when cleanup is enabled.
- The bearer token is stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Network failure, invalid output, and timeout all preserve a usable local transcript.
- Please report security issues according to [SECURITY.md](SECURITY.md).

## Acknowledgements

Chat is derived from [Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) and keeps its MIT license and history. The local-speech-plus-cleanup approach and literal post-processing constraints were also informed by [zachlatta/freeflow](https://github.com/zachlatta/freeflow). See [NOTICE](NOTICE) for attribution.

## Upgrading from GlowScribe

The first Chat launch copies existing preferences and application-support data from the previous GlowScribe identity without deleting the old data. A stored Bedrock key is moved to Chat's Keychain service on first use. After a verified install, the installer moves `/Applications/GlowScribe.app` to the Trash so the replacement remains recoverable.

## License

MIT. See [LICENSE](LICENSE).
