# Changelog

## Unreleased

- Keep transcript text, dropped-file paths, and provider error payloads out of diagnostic logs.
- Leave a failed targeted paste on the clipboard and show a visible recovery message instead of redirecting it into another app.
- Simplify the source install instructions, fix README casing for case-sensitive clones, clarify Bedrock access troubleshooting, and separate deterministic tests from interactive UI tests.
- Make the first-run shortcut truthful: new users get the permission-free key combination by default, while `Fn`/globe is a visible onboarding choice with Input Monitoring guidance and automatic hotkey activation after permission is granted.
- Show model download sizes, percentage progress, and a clear ready state during onboarding.
- Give WorkFlow its own macOS bundle identity while non-destructively copying preferences and History/models and securely moving provider credentials from earlier Chat and GlowScribe installs.
- Move legacy provider credentials in the background at launch and retry stale Keychain-item cleanup without blocking the app window.
- Explain the one-time macOS permission re-grant required after the identity migration.
- Keep the release checks covering first-run shortcut behavior and Escape protection.

## 0.5.1 — 2026-08-23

- Add an accessible **Ignore Esc while recording** setting so accidental Escape presses cannot discard an active dictation.

## 0.5.0 — 2026-08-22

- Add Homework, Technical, and Everyday cleanup modes with distinct grounded rewriting contracts.
- Add local source-to-final token estimates, per-dictation History badges, and monthly cross-mode efficiency comparisons.
- Keep provider billing tokens separate from local efficiency estimates and exclude failed cleanup fallbacks from comparisons.

## 0.4.0 — 2026-08-22

- Rename the visible app and executable to WorkFlow with an independent purple waveform identity while retaining the existing bundle identifier for permission and data continuity.
- Upgrade FluidAudio from 0.15.4 to 0.15.6 and pass the selected language into Parakeet v3.
- Make cold-start dictation wait for model loading and accept short commands down to 350 ms.
- Serialize `Fn` press/release state and use one global, one-shot paste gate so an older async result cannot overwrite the newest dictation.
- Keep each configured cleanup provider on a reusable HTTP session and reduce short-dictation output allowances.
- Add a default $0.25 monthly Bedrock estimated-cost stop with local fallback and History status.
- Add VoiceOver labels and hints to primary history, settings, cleanup, and shortcut controls.
- Add immediate-use, agent-assisted setup, cost, privacy, and notarized-release documentation.
