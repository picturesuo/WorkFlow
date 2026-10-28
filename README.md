<p align="center">
  <img src="docs/chat-icon.png" width="144" height="144" alt="WorkFlow ivory W ribbon icon on a charcoal rounded square">
</p>

<h1 align="center">WorkFlow</h1>

<p align="center">
  Hold <kbd>Fn</kbd> or a shortcut, speak, and get text written the way you want.
</p>

WorkFlow is a free, open-source dictation and meeting-transcription app for the Mac. Speech-to-text runs on your Mac with Parakeet or Whisper, so there are no transcription API fees. Optional AI cleanup goes through a provider you pick; with Amazon Nova Micro it cost the maintainer about half a cent in September 2026.

## Monthly usage cost

Real numbers from the maintainer's Mac for September 2026:

- About 260 dictations, roughly 2.8 hours of recording.
- 253 of them went through AI cleanup with Amazon Nova Micro on Bedrock: about 81K input and 14K output tokens.
- Estimated cost: **about $0.005**, so half a cent for the whole month.

That's an estimate from the token counts WorkFlow recorded, not an AWS bill. It uses AWS's US on-demand price for Nova Micro: $0.035 per million input tokens and $0.14 per million output tokens ([AWS pricing](https://aws.amazon.com/bedrock/pricing/), checked October 24, 2026). Transcription had no API fees. Create with AI and Learn came out in October, so the September number is dictation cleanup only.

Your number depends on how much you talk, the language, the dictation mode, and the provider. **Settings → Provider & Cost** shows this month's estimate as you go.

## Monthly running cost

**$0 when you're not dictating.** No subscription, no WorkFlow server, and no transcription API fees, since transcription runs on your Mac (electricity and hardware not included). Cleanup bills only when WorkFlow sends your provider something.

As a thought experiment, talking nonstop for a month with Bedrock cleanup on works out to roughly **$1.60-$2.10** at the prices above (30 days × 24 hours at 150 words a minute and 1.33 tokens a word, output about as long as input, plus a 250-370 token prompt per request, sent once per dictation or per 4,800-character chunk of a long recording). That's a rough range, not a cap or a promise: WorkFlow isn't built as an always-on recorder, Homework mode can write more than you said, and the default **$0.25 monthly stop** pauses Bedrock cleanup after roughly 4-5 days of this, after which dictation keeps your original transcript. Local Ollama cleanup has no per-request fee; Azure OpenAI and other OpenAI-compatible APIs bill at their own rates, which WorkFlow doesn't estimate.

## Custom filters

Make cleanup write the way a class, job, or app wants:

1. Open **Settings → Cleanup → Custom filters**.
2. Choose **Create with AI** and type or speak what should change, or choose **New filter** and write the instructions yourself.
3. Review the name, base mode, **Write quantities as digits**, and instructions, then save.
4. Pick the filter under **Dictation mode**. The next dictation uses it; no restart needed. Edits apply to the next dictation too.

A couple of ideas:

> Join closely related sentences with semicolons.

> Capitalize product names and hyphenate compound modifiers.

Each filter builds on a built-in mode: **Everyday** (light cleanup in your voice), **Technical** (compact instructions for coding agents), **Homework** (complete explanations, numbers as digits), or **Writing** (your own voice for essays, long sentences and semicolons kept). Saved filters show up next to those modes under **Dictation mode** in the main window and the menu-bar **Dictation Mode** menu. Three starters ship with the app: Everyday with digits, Everyday with words, and More hyphens.

Filters are instructions for the model, not guarantees. WorkFlow checks the numbers in the output against what you said, and if they don't match or cleanup fails, you get your original transcript. Filters need AI cleanup turned on.

Digits don't depend on the model. Built-in Homework, and any filter with **Write quantities as digits** turned on, has WorkFlow write plain spoken quantities as digits itself after a successful cleanup, so "fifteen percent", "twenty twenty six", and "one hundred five" become 15%, 2026, and 105. The same number check runs on the result. Zero to nine on their own, ordinals, times, codes and phone numbers, numbers in quotes, names, and titles, and other back-to-back numbers keep their words. If cleanup fails, you still get your original transcript. Writing "digits" in a filter's instructions only asks the model; the checkbox is what turns this on.

## Questions stay questions

Cleanup rewrites what you said. It doesn't answer it. A question you dictate comes back as that question, and a request, even one aimed at an AI or one that says to ignore the rules, comes back as that request. That rule sits above every mode and custom filter, and the transcript goes to the provider marked as text to rewrite.

If the reply drops a question you asked, or is made of material you didn't say, like an answer, advice, a poem, or a joke, WorkFlow uses your original transcript. A missing question mark alone is fine. These checks catch clear answers, not every subtle change of meaning.

With **Create with AI**, nothing leaves your Mac until you press **Send**. You can paste an essay or problem set you already finished as an example; only the name, base mode, digits choice, and instructions are saved, never the example.

## Learn from finished writing

This is separate from filters. Paste or drop a document you finished from your dictations into **Settings → Personalize → Learn from finished writing**, pick a mode, and choose **Learn**. PDF, Word, RTF, OpenDocument, Markdown, and plain text work, up to 100,000 characters.

WorkFlow matches the document to your History and keeps only small style edits it can confirm, such as a spelling, a dropped filler, semicolon joins, or digits. Edits that change values, negations, or meaning are left out. Each learned preference is checked against your edits, applied to that mode automatically, and can be switched off or deleted. Custom filters are never changed.

## Music while you dictate

To keep music or a video playing while you dictate, turn on **Settings → Dictation → Reduce background audio**. Dictation then records through macOS voice processing, the echo cancellation and noise suppression calls use. Apple describes it as taking audio the Mac plays out of what the microphone hears, so it may reduce music from this Mac's speakers and steady noise. Your music keeps playing; macOS may lower it slightly while you dictate. It's off by default, and meetings always record the microphone as is, so people on a call stay in the transcript.

It reduces background audio; it doesn't promise to remove it:

- How much music or ad audio from other apps it removes depends on your Mac, speakers, and apps, and hasn't been measured on real hardware yet.
- Music, ads, or voices from another device or people in the room aren't echo, so they aren't cancelled. macOS's Voice Isolation mic mode, in Control Center while WorkFlow records, applies too and may help.
- With headphones the music never reaches the mic, so there's nothing to remove.
- If voice processing can't start, that dictation records the microphone as is and Settings says so.
- WorkFlow never deletes words from your transcript to drop lyrics or ads.

## Privacy

Audio never leaves your Mac. With cleanup on, only transcript text goes to the one provider you pick: Amazon Bedrock, Azure OpenAI, local Ollama, or any OpenAI-compatible API. **Send** in Create with AI shares your request and any pasted example. **Learn** shares only the short matched edits with a few words around each; the document itself is read on your Mac and not stored. New dictations keep their original transcript on your Mac until you delete them. Keys live in macOS Keychain, and credentials and transcripts are never logged.

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

## Development

<details>
<summary>Headless test command</summary>

```bash
WORKFLOW_TEST_BUNDLE_ID="com.picturesuo.WorkFlow.fmtest.run$$"
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
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER="$WORKFLOW_TEST_BUNDLE_ID"
```

The skipped suites launch TextEdit, switch the keyboard layout, or show a panel; run them interactively. The separate bundle identifier keeps the test host out of WorkFlow's own preferences, and the shell PID suffix gives each run its own preferences domain so concurrent runs do not overwrite each other. Pass the same `WORKFLOW_TEST_BUNDLE_ID` to `build-for-testing` and `test-without-building` when you split the steps. Releases follow [docs/RELEASING.md](docs/RELEASING.md).

</details>

## Attribution and license

WorkFlow is derived from [Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) under the MIT license and informed by [zachlatta/freeflow](https://github.com/zachlatta/freeflow); see [NOTICE](NOTICE). It is independent of other dictation products. Security reports: [SECURITY.md](SECURITY.md). MIT, see [LICENSE](LICENSE).
