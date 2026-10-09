<p align="center">
  <img src="docs/chat-icon.png" width="144" height="144" alt="WorkFlow purple waveform icon">
</p>

<h1 align="center">WorkFlow</h1>

<p align="center">
  Hold <kbd>Fn</kbd> or a shortcut, speak, and get text written the way you want.
</p>

WorkFlow is open-source dictation for the Mac. Speech recognition runs locally with Parakeet or Whisper. An optional cleanup pass fixes fillers and punctuation, and you can shape that cleanup with custom filters you create by talking to an AI.

## Filters you describe, not configure

Open **Settings → Cleanup → Custom filters** and choose **Create with AI**. Type or speak what should change, for example:

> Write numbers as digits, "square root" as √, and "times" as x with a space on each side.

Optionally name the class or assignment, and paste a finished example so the filter matches its style. Press **Send**. The assistant proposes a name, a base mode, and instructions. Edit the proposal directly or ask for changes, then choose **Save filter** and leave **Use for new dictations** checked. Nothing is saved or sent until you press those buttons.

Now dictation like "the square root of sixteen times three" comes out as `√16 x 3` instead of a sentence of words. A filter can only format what you actually said: `twenty five` becomes `25`, but it will never solve, round, or invent a value. If a result cannot be matched to your words, WorkFlow falls back to the plain local transcript.

Three starting points ship with the app:

| Filter | Spoken | Written |
|---|---|---|
| Everyday with digits | twenty five dollars | 25 dollars |
| Everyday with words | 25 dollars | twenty-five dollars |
| More hyphens | a well known author | a well-known author |

Saved filters appear next to the built-in modes in the main window and the menu-bar **Writing Mode** menu. Each filter sits on top of one of these modes:

- **Everyday** lightly cleans speech while preserving your natural voice and level of detail.
- **Technical** produces compact, unambiguous instructions for computers and coding agents.
- **Homework** develops complete explanations and preserves every idea. Longer output is expected.

## Why WorkFlow

- Audio never leaves your Mac. Only transcript text reaches the one cleanup provider you turn on.
- Cleanup edits literally. Names, numbers, paths, and identifiers stay as you said them, and any failure returns usable local text.
- Filters are plain language, reviewed by you, and reusable across every app.
- Choose Amazon Bedrock, Azure OpenAI, local Ollama, or any OpenAI-compatible API. Keys live in macOS Keychain.
- Personal vocabulary, per-app rules, meeting transcription, and searchable History are built in.

## Install with your AI

The current release ships as source only; there is no notarized download yet, so do not bypass Gatekeeper for an unsigned build. The fastest path is to hand this to a coding agent on your Mac:

```text
Install WorkFlow from https://github.com/picturesuo/WorkFlow by following
docs/AGENT_SETUP.md in that repository. Clone with submodules, install the
build dependencies, run the focused tests, then run Scripts/install-local.sh
and open /Applications/WorkFlow.app. Never ask me for an API key: I will type
it into WorkFlow's secure settings field myself. Leave Apple signing identity,
Microphone, Accessibility, and Input Monitoring approvals to me.
```

To do it by hand:

```bash
git clone --recurse-submodules https://github.com/picturesuo/WorkFlow.git
cd WorkFlow
brew install cmake libomp rust
./Scripts/install-local.sh
open /Applications/WorkFlow.app
```

Requirements: Apple Silicon, macOS 14 or newer, Xcode, Homebrew, Rust, and Git. On macOS 26 or newer the installer needs an Apple-issued signing identity so microphone permission keeps working. The [quickstart](docs/QUICKSTART.md) covers permissions, the first model download, and optional provider setup.

## Privacy

Speech recognition and the filter assistant's microphone both run on your Mac. Enabling a cleanup provider sends transcript text to that provider. When you press **Send** in the filter assistant, your request, class name, and pasted example go to the same provider. Examples are never saved. Credentials and transcripts are never written to logs.

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

The skipped suites launch TextEdit, switch the keyboard layout, or present a visible panel; run them in an interactive session. The Xcode scheme stays `OpenSuperWhisper` for source history. Releases follow [docs/RELEASING.md](docs/RELEASING.md).

</details>

## Attribution and license

WorkFlow is derived from [Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) under the MIT license and informed by [zachlatta/freeflow](https://github.com/zachlatta/freeflow). See [NOTICE](NOTICE). WorkFlow is not affiliated with Wispr Flow, Superwhisper, or OpenSuperWhisper. Report security issues per [SECURITY.md](SECURITY.md). MIT, see [LICENSE](LICENSE).
