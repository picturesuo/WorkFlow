<p align="center">
  <img src="docs/chat-icon.png" width="144" height="144" alt="WorkFlow purple waveform icon">
</p>

<h1 align="center">WorkFlow</h1>

<p align="center">
  Hold <kbd>Fn</kbd> or a shortcut, speak, and get text written the way you want.
</p>

WorkFlow is an open-source dictation and meeting-transcription app for the Mac. Speech-to-text runs locally and free with Parakeet or Whisper. An optional AI cleanup pass fixes fillers and punctuation, and custom filters shape it for each kind of work: digits and symbols for math, semicolons and dashes for essays, compact commands for coding agents.

## A filter for every kind of work

Open **Settings → Cleanup → Custom filters**, choose **Create with AI**, and type or speak what should change:

> Write numbers as digits, "square root" as √, and "times" as x with a space on each side.

If the style is hard to describe, name the class or assignment and paste an essay or problem set you already finished; the filter is fitted to it. Nothing leaves the app until you press **Send**, which sends the request, class name, and example to your cleanup provider. It proposes a name, base mode, and instructions; edit them or ask for changes. Nothing is stored until you choose **Save filter**, with **Use for new dictations** checked to make it your writing mode.

Now "the square root of sixteen times three" comes out as `√16 x 3`. The filter is instructed to format, not solve or change, what you said, and WorkFlow checks the output: `twenty five` may become `25`, but a number, √, or × it cannot match to your words makes the dictation fall back to the local transcript.

Three starters ship with the app; each row shows the style it asks for:

| Filter | Spoken | Asks for |
|---|---|---|
| Everyday with digits | twenty five dollars | 25 dollars |
| Everyday with words | 25 dollars | twenty-five dollars |
| More hyphens | a well known author | a well-known author |

Saved filters sit beside the built-in modes in the main window and menu-bar **Writing Mode** menu; each builds on a mode:

- **Everyday** lightly cleans speech while preserving your natural voice and level of detail.
- **Technical** produces compact, unambiguous instructions for computers and coding agents.
- **Homework** develops complete explanations and preserves every idea. Longer output is expected.

## Why WorkFlow

- Audio never leaves your Mac; only transcript text reaches the one provider you enable.
- Cleanup is instructed to edit literally. Output numbers are checked against your words, and a failed or rejected cleanup returns local text.
- Filters are plain language, reviewed by you, and work in every app.
- Transcription is free. AI cleanup is billed by the provider you choose and can cost very little depending on model and use; credit eligibility is up to that provider.
- Choose Amazon Bedrock, Azure OpenAI, local Ollama, or any OpenAI-compatible API. Keys live in macOS Keychain.
- Personal vocabulary, per-app rules, meeting recordings saved to History, and search are built in.

## Install with your AI

The current release is source only with no notarized download yet; do not bypass Gatekeeper for an unsigned build. Hand this to a coding agent on your Mac:

```text
Install WorkFlow from https://github.com/picturesuo/WorkFlow by following
docs/AGENT_SETUP.md in that repository. Clone with submodules, install the
build dependencies, run the focused tests, then run Scripts/install-local.sh
and open /Applications/WorkFlow.app. Never ask me for an API key: I will type
it into WorkFlow's secure settings field myself. Leave Apple signing identity,
Microphone, Accessibility, and Input Monitoring approvals to me.
```

By hand:

```bash
git clone --recurse-submodules https://github.com/picturesuo/WorkFlow.git
cd WorkFlow
brew install cmake libomp rust
./Scripts/install-local.sh
open /Applications/WorkFlow.app
```

Requirements: Apple Silicon, macOS 14 or newer, Xcode, Homebrew, Rust, and Git. macOS 26 needs an Apple-issued signing identity so microphone permission works. See the [quickstart](docs/QUICKSTART.md) for permissions and provider setup.

## Privacy

Audio stays on your Mac, including the filter assistant's microphone. Enabling a cleanup provider sends transcript text to it. In the filter assistant, **Send** transmits your request, class name, and pasted example to that provider; **Save filter** stores only the name, base mode, and instructions, never the example. Credentials and transcripts are never logged.

## Development

<details>
<summary>Headless test command</summary>

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -scheme OpenSuperWhisper \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:OpenSuperWhisperTests \
  -skip-testing:OpenSuperWhisperTests/ClipboardUtilPasteIntegrationTests \
  -skip-testing:OpenSuperWhisperTests/ClipboardUtilKeyboardLayoutTests \
  -skip-testing:OpenSuperWhisperTests/KeyboardLayoutProviderTests \
  -skip-testing:OpenSuperWhisperTests/IndicatorWindowGeometryTests/testWindowKeepsPanelSizeAfterPresent \
  CODE_SIGNING_ALLOWED=NO
```

The skipped suites launch TextEdit, switch the keyboard layout, or show a panel; run them interactively. Releases follow [docs/RELEASING.md](docs/RELEASING.md).

</details>

## Attribution and license

WorkFlow is derived from [Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) under the MIT license and informed by [zachlatta/freeflow](https://github.com/zachlatta/freeflow); see [NOTICE](NOTICE). It is independent of other dictation products. Security reports: [SECURITY.md](SECURITY.md). MIT, see [LICENSE](LICENSE).
