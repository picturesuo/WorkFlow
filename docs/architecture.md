# WorkFlow architecture: target and migration

One page. The models behind it are in [state-machines.md](state-machines.md); the numbers are in [perf/](perf/).

Order of work: what a user feels comes first (latency they wait through, hangs and hitches, screens that look or behave off). A machine is migrated when that removes a measured delay or a proven bug, not for its own sake.

## Where we are going

State that today lives in flags, optionals and mirrored copies across view models, singletons, timers and Tasks moves, one machine at a time, into this shape:

```
event sources            pure core                    effect runner                 views
(hotkey tap, recorder,   reduce(state, event)         one isolated owner per        render state,
 timers, engine, UI)  -> -> (state, [effect])      -> machine runs the effects,  -> send events,
                         DictationCore (SwiftPM)      feeds results back as events  own nothing
```

- **Pure cores** live in the `DictationCore` Swift package (Foundation only, Swift 6 language mode, no AppKit, no clocks, no I/O). Each machine is `enum <Name>Core { State, Event, Effect, reduce }` with its transition table in the doc comment, one unit test per table row, and property tests that feed random event sequences and check the invariants after every step. `swift test --package-path DictationCore` runs in seconds, also under Thread Sanitizer.
- **Effect runners** live in the app target. A runner owns the machine's state, applies events in arrival order, and executes the returned effects. It is isolated: `@MainActor` for UI-facing machines, a lock plus a serial queue for the recorder (hardware calls must stay off the main thread). Runners contain no decisions, only "do what the effect says".
- **Views render state.** A view reads the owner's published state and sends events. It never keeps its own copy of "are we recording".

## Module boundaries

| Module | Holds | May import |
|---|---|---|
| `DictationCore` (package) | reducers, states, events, effects | Foundation |
| App: runners (`AudioRecorder`, `ShortcutManager`, `ProcessExitGate`, later a dictation session store) | state ownership, effect execution, hardware and OS calls | DictationCore, AVFoundation, AppKit |
| App: services (engines, cleanup pipeline, `RecordingStore`) | work the effects ask for | no UI |
| App: views and view models | rendering, user intent to events | SwiftUI |

## One owner per piece of state

| State | Owner today | Target owner |
|---|---|---|
| Who owns the microphone, capture phase | `AudioRecordingSessionGate` + `capture` + `currentRecordingURL` + two published flags, spread over a lock, a queue and the main thread | `RecorderCore` state inside `AudioRecorder` |
| Hotkey gesture (press, hold, double-press, chord) | six vars in `ShortcutManager`, one of them a mirror of the session | `TriggerCore` state inside `ShortcutManager`; "is a dictation capturing" is asked of the session owner, never mirrored |
| In-flight native library calls at exit | nobody | `ExitGateCore` state inside `ProcessExitGate` |
| Dictation session phase (capturing, stopping, transcribing, refining, notice) | `IndicatorViewModel` flags and timers, duplicated in `ContentViewModel` | one `DictationSessionCore` store that the capsule and the main-window dock both render |
| Paste arbitration between overlapping dictations | `LatestDictationGate` | folded into the session store |
| History list paging and search | `RecordingHistoryModel` (already close to explicit) | same, as a core if it changes again |

## Migration order (every step ships, the app keeps working)

1. **Measure**: signposts on the four flows and a repeatable benchmark (done first; `Scripts/perf/`).
2. **Recorder**: `AudioRecorder` drives its ownership and capture lifecycle from `RecorderCore`. Fixes a capture that dies on its own deleting the audio and leaving the UI "listening", and cancel blocking the main thread.
3. **Process exit**: native whisper.cpp calls pass through `ProcessExitGate`, so quitting waits for them instead of aborting in a static destructor.
4. **Trigger**: `ShortcutManager` drives gestures from `TriggerCore` and stops mirroring the session.
5. **Session**: `IndicatorViewModel`'s flags become one `DictationSessionCore` phase; the main-window dock renders the same store instead of its own copy. `LatestDictationGate` folds in.
6. **Queue and engine reservation** (`TranscriptionQueue`, `TranscriptionService`): same treatment, only if they show up in a trace or a bug again.

Each step lands as its own change with: characterization tests first, the repro test going from failing to passing, property tests on the core, Thread Sanitizer and Swift 6 strict concurrency clean on the touched module, and a benchmark re-run.

## Deliberately not changing

- **No big-bang rewrite, no new architecture framework.** Plain reducers and small runners; SwiftUI views stay as they are until their machine migrates.
- **The app module stays in Swift 5 language mode.** Only `DictationCore` is Swift 6; flipping the whole app is a separate, mechanical project.
- **Delivery policy for overlapping dictations** ("the newest dictation is pasted, older ones go to History") is a product decision that exists and is tested. The session core will encode it as is. Delivering every dictation in order is listed in state-machines.md as a recommendation, not done.
- **Engines, cleanup providers, learning, filters, onboarding, settings.** Not on the measured flows, no failure evidence found.
- **`RecordingStore` on a single `DatabaseQueue`.** Fine at the measured sizes; revisit only with a trace.
- **Meeting recording and the in-window record button keep their behavior**; they gain correct handling of a capture that ends on its own through the recorder step.
