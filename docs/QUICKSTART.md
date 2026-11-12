# WorkFlow quickstart

## Install

### Public release status

A notarized `WorkFlow-…-macOS-arm64.zip` isn't published yet, so use the local source build below, which builds `master`. Do not bypass Gatekeeper for an unsigned or unnotarized build. Future signed builds will appear on [WorkFlow Releases](https://github.com/picturesuo/WorkFlow/releases/latest).

### Local source build

On an Apple Silicon Mac with macOS 14 or newer:

```bash
git clone --recurse-submodules https://github.com/picturesuo/WorkFlow.git
cd WorkFlow
brew install cmake libomp rust
./Scripts/install-local.sh
open /Applications/WorkFlow.app
```

The first build downloads dependencies and can take several minutes. WorkFlow now uses its own `com.picturesuo.WorkFlow` identity. When upgrading from Chat or GlowScribe, it copies preferences and History/models forward without deleting the old data and moves provider credentials into WorkFlow's Keychain identity. macOS privacy grants cannot be copied, so approve WorkFlow once under Microphone, Accessibility, and, if selected, Input Monitoring. On macOS 26 or newer, the installer can reuse the exact trusted signer from a working installation. Otherwise, if it reports that no Apple-issued signing identity exists:

1. Open Xcode → Settings → Accounts.
2. Add an Apple Account and select **Manage Certificates**.
3. Create an **Apple Development** certificate.
4. Run `./Scripts/install-local.sh` again.

An agent can handle the terminal steps, but the user should complete Apple-account dialogs and enter API keys personally. See [AGENT_SETUP.md](AGENT_SETUP.md).

## Grant permissions

When WorkFlow opens, allow:

1. **Microphone**: records speech locally.
2. **Accessibility**: pastes into the app that was focused when recording began.
3. **Input Monitoring**: needed only when you choose `Fn`/globe, another single-modifier shortcut, or `Control`+`Fn`.

If a prompt is missed, open System Settings → Privacy & Security and enable the missing permission. WorkFlow detects a newly granted Input Monitoring permission and activates the selected shortcut automatically.

## Settings at a glance

Settings (⌘,) has four panes; ⌘1 to ⌘4 switch between them, and Settings reopens on the pane you last used.

- **Dictation**: the shortcut (and an optional second key, or **Control + Fn (hold both)**, where Fn or Control alone does nothing), whether you hold or tap to record, the speech model, the language, and whether text is pasted and kept on the clipboard. Sounds, Escape, startup, meeting cleanup, History storage, and Whisper decoding wait under **More options**.
- **Cleanup**: AI cleanup on or off, the four dictation modes with an example each, and your custom filters.
- **Personalize**: learning from finished writing, personal vocabulary, per-app rules, and a JSON backup.
- **Provider & Cost**: the cleanup provider and its key, the monthly estimated-cost stop, and this month's usage.

## Main window at a glance

- **Toolbar**: search History, **More** (⋯) for **Start Meeting Recording…** and **Delete All Recordings…**, and Settings. While a meeting records, a stop button joins the toolbar and the record button stops and saves it.
- **History**: dictations grouped by day, newest first. Each row shows what you said first, then a quiet line with the time, the length, and how the text was produced. That line ends with **Copy**; the ⋯ menu beside it, or a right-click, also offers Play Recording, Regenerate Transcript, and Delete Recording. A failed transcription that kept its audio shows **Regenerate** in place of Copy, and a long transcript opens with **Show full text**. A recording WorkFlow closed on before transcribing it (a quit, crash, or force quit) comes back at the next launch as a failed row marked "Recovered recording"; nothing is transcribed or pasted until you choose **Regenerate**, and you can delete it like any other row.
- **Dictation bar**: it floats over the bottom of History, which scrolls beneath it. It holds the dictation mode and **Learn…**, what dictation is doing now with your shortcut, the microphone menu (⌄), and the record button. While it listens, the button shows a small vermilion stop square and a faint halo that follows your microphone's level, so a still halo means the microphone hears nothing.

## First dictation

1. In onboarding, keep the permission-free `Option`+backtick shortcut or choose `Fn`/globe and enable Input Monitoring.
2. Download the recommended Parakeet v3 model (about 483 MB). Onboarding shows its percentage and marks it **Ready** when complete.
3. Choose **Homework**, **Technical**, **Everyday**, or a saved custom filter in the main window or WorkFlow's menu-bar menu.
4. Put the cursor in any text field, hold your chosen shortcut, speak, and release it.
5. Keep the cursor in the intended field until text appears. WorkFlow targets the app that was active when recording began, but changing fields inside that app can redirect the paste.

While you speak, a small capsule just above the text cursor (or near the top of the screen when there isn't one) shows a dot, a thin waveform, and the clock. Drag it anywhere and later dictations appear there too; double-click it and the next dictation appears by the cursor again. Dragging it doesn't stop the recording or take focus from your app.

With Parakeet, a long dictation is recognized while you speak. WorkFlow cuts it at pauses into pieces of up to about 14 seconds and recognizes each one as soon as it's complete, so when you release the shortcut only the last piece is left, however long you talked. The words are the same as recognizing the whole recording afterward, and if the recording isn't exactly what was heard, WorkFlow recognizes the saved file instead.

Use Homework for developed prose, Technical for compact commands sent to computers or coding agents, and Everyday for natural messages.

The main window shows this month's time saved and how many times faster than typing, for example **≈12 min saved · 3.1× faster**. **Settings → Dictation → Speaking vs typing this month** has the details and the typing speed:

- **Active speech** is the time the speech detector on your Mac heard you talking. Pauses, thinking, reading, and waiting for the text aren't counted. It's an estimate: other voices or a steady hum can count as speech, and whispers can be missed.
- **Time saved** is the estimated time to type the words you said, as the recognizer heard them before cleanup, at an assumed typing speed (40 WPM unless you change it), minus active speech. Cleanup that writes more than you said doesn't raise it. **× faster** is that typing time divided by active speech. Both can show that speaking was slower. Editing afterward isn't measured, and the typing speed is your assumption, not a measurement.
- Totals add words and seconds across dictations before dividing. Dictations from before WorkFlow measured active speech, meetings, imported audio, failures, and items still processing are listed as not counted, and a regenerated dictation keeps its first figures.

History labels each comparable dictation with its own time saved and × faster. Provider billing tokens stay under **Settings → Provider & Cost**.

To make a mode more specific, open **Settings → Cleanup → Custom filters**, choose **New filter**, pick a base mode, and describe the change in plain language, for example "Use more hyphens." Turn on **Write quantities as digits** if you want numbers as digits. The filter appears next to the built-in modes right away, and the next dictation uses it once you pick it.

Cleanup never answers what you dictate: a question or request comes back rewritten as that question or request, or as your original transcript.

WorkFlow launches at login and stays available in the menu bar by default. Dictation works entirely locally before any API is configured.

If you sometimes press Escape accidentally, enable **Settings → Dictation → More options → Ignore Esc while recording**. Escape will then leave active dictations recording; use the configured recording shortcut to finish normally. Escape while a stopped dictation is still transcribing cancels its paste either way; the text stays in History.

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

**Auto** can pick the filter for you. Give a filter a few trigger phrases in its editor, then choose **Auto** under **Dictation mode**, or turn on **Automatic choice** in **Settings → Cleanup**. When at least two of a filter's phrases come up in one dictation, Auto uses that filter; one phrase, a tie, or none falls back to the filter you set under **When unsure, use**. Auto is deterministic and runs on your Mac between transcription and cleanup: no extra request, no model, and nothing read from your screen. Picking a mode or filter by hand turns Auto off again, and History shows which filter Auto chose.

Filters are instructions for the model, not guarantees. WorkFlow checks the numbers in the output against what you said, and if they don't match or cleanup fails, you get your original transcript. Filters need AI cleanup turned on.

Digits don't depend on the model. Built-in Homework, and any filter with **Write quantities as digits** turned on, has WorkFlow write plain spoken quantities as digits itself after a successful cleanup, so "fifteen percent", "twenty twenty six", and "one hundred five" become 15%, 2026, and 105. The same number check runs on the result. Zero to nine on their own, ordinals, times, codes and phone numbers, numbers in quotes, names, and titles, and other back-to-back numbers keep their words. If cleanup fails, you still get your original transcript. Writing "digits" in a filter's instructions only asks the model; the checkbox is what turns this on.

With **Create with AI**, nothing leaves your Mac until you press **Send**. You can paste an essay or problem set you already finished as an example; only the name, base mode, digits choice, and instructions are saved, never the example.

## Learn from finished writing

Finish a document from your dictations, even weeks later, then paste or drop it into **Settings → Personalize → Learn from finished writing**, or choose **Learn…** in the dictation bar. PDF, Word, RTF, OpenDocument, Markdown, and plain text work, up to 100,000 characters. **Check matches** shows what WorkFlow found without sending anything; **Learn** learns from it.

WorkFlow finds the dictations inside the document among your 5,000 most recent in History, compares them with your edits, and keeps small style preferences it can check against those edits: spacing, hyphenation, and capitalization, fillers such as "um" or "basically", semicolon joins, digits, and contractions. Each dictation teaches the mode or saved filter it was made with; a saved filter keeps its own list, and its saved instructions never change. Older History with no recorded mode teaches the mode you pick for it.

Edits that change a value or a negation are left out, and so is a word swapped for another, such as "lunch" → "launch" or a respelled name: you can add one to Vocabulary yourself, but it is never learned on its own. These checks can't catch every change of meaning, so look over what was learned. **Details** lists every matched edit, what was left out and why, and the exact lines sent.

It can only match dictations that are still in History, and History saved before WorkFlow kept the original transcript is compared by its final text only. Learn uses your cleanup provider and sends only the short matched edits with a few words around each, never the whole document.

This is preference learning, not model training: no model is retrained. Preferences apply automatically to their mode or filter, and each one can be switched off or deleted; Regenerate never brings back one you removed.

## Questions stay questions

Cleanup rewrites what you said. It doesn't answer it. A question you dictate comes back as that question, and a request, even one aimed at an AI or one that says to ignore the rules, comes back as that request. That rule sits above every mode and custom filter, and the transcript goes to the provider marked as text to rewrite.

If the reply drops a question you asked, or is made of material you didn't say, like an answer, advice, a poem, or a joke, WorkFlow uses your original transcript. A missing question mark alone is fine. These checks catch clear answers, not every subtle change of meaning.

When you restart by saying the same words again, as in "I can't, I can't make it" or "what's the, um, what's the status", cleanup may keep just one take. The question or negation in it still has to come through, and a reply that drops it gets your original transcript. A percent or a minus you say twice, as in "5%, 5%, and 10%" or "ten minus two, minus two", has to stay twice, even when you meant a restart.

## If the microphone stops while you record

When the microphone goes away in the middle of a recording, for example a device is unplugged, a headset disconnects, or the recorder fails, WorkFlow keeps what it recorded until then:

- A dictation ends there, is transcribed and delivered as usual, and the indicator shows **Recording cut short**.
- A meeting is saved to History with the audio so far, and WorkFlow tells you it stopped early.
- Esc still discards the recording.

Starting a recording also stops a History recording that is playing, so the microphone doesn't record it.

## Microphones with several inputs

WorkFlow records every input channel of the microphone you pick, and a file you drop in can be stereo or surround. The speech model takes one channel, so WorkFlow mixes the channels that carry sound into one before it transcribes:

- A voice on any single input, such as the second input of an audio interface, is used at its own level.
- Idle inputs more than 40 dB under the loudest one are left out, so they don't thin the voice.
- Several sources, such as a microphone plus call audio on an aggregate device, are averaged.
- Two channels that cancel each other use the louder one alone.

The audio saved in History keeps all of its channels; only what the model hears is mixed. A recording with one channel is read exactly as before.

## Music while you dictate

To keep music or a video playing while you dictate, turn on **Settings → Dictation → Reduce background audio**. Dictation then records through macOS voice processing, the echo cancellation and noise suppression calls use. Apple describes it as taking audio the Mac plays out of what the microphone hears, so it may reduce music from this Mac's speakers and steady noise. Your music keeps playing; macOS may lower it slightly while you dictate. It's off by default, and meetings always record the microphone as is, so people on a call stay in the transcript.

It reduces background audio; it doesn't promise to remove it:

- How much music or ad audio from other apps it removes depends on your Mac, speakers, and apps, and hasn't been measured on real hardware yet.
- Music, ads, or voices from another device or people in the room aren't echo, so they aren't cancelled. macOS's Voice Isolation mic mode, in Control Center while WorkFlow records, applies too and may help.
- With headphones the music never reaches the mic, so there's nothing to remove.
- If voice processing can't start, that dictation records the microphone as is and Settings says so.
- If voice processing stops mid-dictation, for example when an audio device changes and it can't restart, the dictation ends there, keeps what you said so far, and the indicator shows **Recording cut short**.
- WorkFlow never deletes words from your transcript to drop lyrics or ads.

## What it costs

There's no WorkFlow subscription, server, or recurring WorkFlow charge. Transcription runs on your Mac, so it has no API fees (electricity and hardware not included). AI cleanup is optional, and provider charges happen only when WorkFlow sends a request to the provider you chose, under your own account: cleaning up a dictation, **Send** in Create with AI, **Learn**, or **Save & Test**.

### Thirty days nonstop

The README's headline is a thought experiment: you talk without stopping for 30 days with Amazon Bedrock cleanup on Nova Micro. It uses AWS's US East (N. Virginia) on-demand price of $0.035 per million input tokens and $0.14 per million output tokens, effective October 1, 2026 in AWS's price list published November 2, 2026 ([AWS pricing](https://aws.amazon.com/bedrock/pricing/)).

- **Words:** 30 days × 24 hours × 60 minutes × 150 words a minute is 6.48 million words, about 8.6 million tokens at 1.33 tokens a word.
- **Output:** cleanup about as long as what you said, so about 8.6 million tokens, or $1.21.
- **Input:** the same 8.6 million transcript tokens ($0.30), plus WorkFlow's cleanup instructions with every request: about 410 tokens in Everyday up to 555 in Homework, by WorkFlow's own local token estimate. Nova's count may differ, and custom filters, learned preferences, and app rules add to it.
- **Requests:** one long recording goes out in pieces of up to 4,800 characters, about 8,100 requests, for **$1.62-$1.67** in all. One-minute dictations make 43,200 requests, for **$2.13-$2.35**.

That assumes every request completes. A long piece may need more than the default three-second cleanup timeout, and a request that times out keeps your original transcript. Homework can write more than you said, which raises the output charge. At this pace the default $0.25 stop pauses Bedrock cleanup after about 3-5 days.

### One real month

In September 2026 the maintainer made about 260 dictations, roughly 2.8 hours of recording. 253 of them went through cleanup with Amazon Nova Micro on Bedrock: 80,712 input and 14,035 output tokens. At the prices above, that's **an estimated $0.0048** for the month, about $0.000019 a cleanup. WorkFlow's cleanup instructions have grown since, so at 100 cleanups like those a day, today's version would come to about $0.07-$0.08 a month.

That's an estimate from the token counts WorkFlow recorded, not an AWS bill, and it's one person's month, not a promise. It leaves out connection tests, requests that failed without a token count, and Create with AI and Learn, which came out in October. Your cost depends on how much you talk, the language, the mode, and the provider; **Settings → Provider & Cost** shows this month's estimate as you go. AWS billing is authoritative.

### The monthly stop

By default, once WorkFlow's estimate for the month reaches $0.25, Bedrock cleanup, Create with AI, and Learn pause until next month, and dictations keep their original transcript. You can set the amount from $0.05 to $10 or turn it off. It covers only Amazon Bedrock with Nova Micro, and it's WorkFlow's estimate, not an AWS billing cap: your AWS bill is authoritative.

### Other providers

Local Ollama cleanup has no per-request fee. OpenAI, Anthropic, Azure OpenAI, and other OpenAI-compatible APIs bill at their own rates, which WorkFlow doesn't estimate and the monthly stop doesn't cover, so set a spend limit with the provider.

### Claude and ChatGPT plans

A Claude or ChatGPT chat subscription isn't an API key, and API use is billed separately from chat plans. As of November 4, 2026, some plans include monthly API credits for one API organization you link to the plan, used through API keys created in that organization:

- **Claude** Max ($100 a month), Ultra ($200), and Team ($20 or $100 per seat, pooled up to $500). Free, Pro, and Enterprise aren't eligible. See [Anthropic's terms](https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-ultra-and-team-plans).
- **ChatGPT** Pro ($100, $200, or $500, matching the Pro tier) and Business ($20 or $100 per paid seat, pooled up to $500 a month, or $6,000 a year when paid annually). Free, Go, Plus, and Enterprise aren't eligible. See [OpenAI's terms](https://developers.openai.com/api/docs/guides/chatgpt-api-credits).

Both need at least seven days on the plan, and unused credits expire instead of rolling over. When they run out and the organization has no purchased credits, API requests stop until more credits arrive. These are Anthropic's and OpenAI's offers and can change, so check the linked pages.

What that means for WorkFlow today: Claude's credits don't cover Claude on Amazon Bedrock. WorkFlow's **Anthropic** and **OpenAI** providers call each company's API directly with a key you create there, so that use bills to the key's API organization like any other API request. WorkFlow connects with an API key you type into its secure settings field, never a chat sign-in, and its cost estimate and monthly stop cover only Amazon Bedrock.

## Optional Bedrock cleanup

1. Create a scoped key in the [Bedrock API keys console](https://console.aws.amazon.com/bedrock/home#/api-keys).
2. Open WorkFlow → Settings → **Provider & Cost**.
3. Choose **Amazon Bedrock** as the cleanup provider and paste the key into the secure field.
4. Select **Save & Test**. A successful test shows input/output tokens and its estimated cost.
5. Keep Nova Micro, the three-second timeout, and the default $0.25 monthly stop for the lowest-cost setup. The stop is WorkFlow's estimate, not a billing cap; when it is reached, Bedrock requests pause until next month and dictations keep their original transcript.

Amazon models are available by default in commercial AWS regions when the key has the required Bedrock permissions. If the test reports `AccessDeniedException`, confirm that the key can invoke Nova Micro in `us-east-1`; an organization policy or restricted account may require an administrator to grant model access.

For prices, a nonstop-month estimate, and the monthly stop, see [What it costs](#what-it-costs).

## Optional OpenAI or Anthropic cleanup

1. Create an API key in the [OpenAI dashboard](https://platform.openai.com/api-keys) or the [Claude Console](https://platform.claude.com/settings/keys).
2. Open WorkFlow → Settings → **Provider & Cost** and choose **OpenAI** or **Anthropic**.
3. Paste the key into the secure field and select **Save & Test**. The key is saved to Keychain only after the test succeeds, and each provider keeps its own key.
4. Keep the recommended model (`gpt-6-luna` for OpenAI, `claude-haiku-5-5` for Anthropic) or enter another model ID. For OpenAI, keep **Reasoning effort** at **None** unless the model needs another value; older models such as GPT-4.1 need **Don't send**. For Anthropic models other than the recommended `claude-haiku-5-5`, WorkFlow leaves extended thinking at the provider's default, which counts toward the reply token limit, so a reply cut short keeps the original transcript.

If the key is rejected, the account is out of quota or rate limited, or the reply is late or would change your meaning, the dictation keeps its original transcript. Usage bills to your OpenAI or Anthropic account; WorkFlow reports tokens but doesn't estimate their prices, and the monthly stop applies only to Amazon Bedrock.

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
