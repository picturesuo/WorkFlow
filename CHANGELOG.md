# Changelog

## Unreleased

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
