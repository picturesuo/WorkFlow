# Implicit state machines in WorkFlow

An implicit state machine is state spread across flags, optionals or duplicate copies, with transitions scattered across callbacks, notifications, timers and Tasks. This page writes each one down explicitly: states, events, transition table, invariants, and the illegal combinations the current code allows. They are ranked by user harm times evidence. A finding counts as **proven** only with a failing test or a trace; everything else is **suspected** and is not fixed blindly.

Sources, in order: the running app under the benchmark in `Scripts/perf/` (numbers in [perf/baseline.md](perf/baseline.md)), failure history (crash reports, fix commits and per-file churn), then the code read with those leads. Churn in the pre-release history, most-fixed first: `ContentView.swift` 78, `Settings.swift` 58, `IndicatorWindow.swift` 50, `OpenSuperWhisperApp.swift` 40, `AudioRecorder.swift` 38, `AppPreferences.swift` 34, `TranscriptionService.swift` 29, `Recording.swift` 29, `ShortcutManager.swift` 25, `TranscriptionQueue.swift` 24.

Target shape and migration order: [architecture.md](architecture.md). Cores live in `DictationCore/`.

## Ranking

Order of work: what a user feels comes first (latency they wait through, hangs and hitches, screens that look or behave off; see [perf/baseline.md](perf/baseline.md)). A machine below is migrated when that removes a measured delay or fixes a proven bug.

| # | Machine | Finding | Harm | Evidence | Status |
|---|---|---|---|---|---|
| 1 | Process exit | Quitting while whisper.cpp runs on a background thread aborts in a static destructor | Crash report on quit; test host aborts after a green run | 8 crash reports on 2026-11-09, one signature | fixed (PR #14) |
| 2 | Recorder | A standard capture that fails on its own deletes the audio, frees the microphone, and tells nobody; the capsule keeps "listening"; a meeting keeps "recording" | Lost dictation or lost meeting with a lying UI | failing tests | proven (test) |
| 3 | Recorder | Cancel waits on the recorder queue from the main thread, behind microphone start | Main-thread stall on every cancelled press (Esc, modifier used as a shortcut) | benchmark `cancel_after_start` | not measured yet: the test identity has no microphone permission (see perf/baseline.md); suspected |
| 4 | Trigger | The shortcut keeps its own copy of "a dictation is active"; while the capsule shows a notice the next press is swallowed | A press that does nothing | failing test | proven (test) |
| 5 | Dictation session | The main window keeps a second copy of the dictation state and shows "Ready to dictate" while a hotkey dictation records; clicking record raises an error alert | Confusing, no data loss | failing test | proven (test) |
| 6 | Dictation session | A press shortly after a stop is treated three ways depending on timing (see below) | Either the new speech is not recorded, or the older text is never pasted | characterized by test | product decision, not changed |
| 7 | Transcription queue, engine reservation | Flags plus database status as state; sentinel strings decide "is this a regeneration" | none observed | none | suspected |
| 8 | Dictation session | A live dictation gets its first History row only after transcription, cleanup and paste. If the process died before that (quit, crash, force quit), only the temporary audio file existed; launch recovery read rows only, and the launch sweep deleted the file once it was 24 hours old. A meeting that died before it was stopped was lost the same way. | Silently lost dictation or meeting | failing test (`RecordingRecoveryTests.testAnOrphanedRecordingBecomesOneFailedRowWithItsAudioAndDate`) | fixed: launch adopts the orphaned audio as a failed row with Regenerate (see below) |

## 1. Process exit (`ExitGateCore`)

`ProcessExitGate` owns "native code is still running" by running `ExitGateCore`. Every whisper.cpp call in `Whis.swift` passes through `gate.run`: once shutdown begins new calls are refused and shutdown waits for the calls in flight, up to a timeout. The crash this fixed was `exit` running C++ static destructors on the main thread while a detached task was inside `whisper_vad_segments_from_samples`; ggml then locked a destroyed mutex and the process aborted (`std::__1::mutex::lock()` <- `ggml_init` <- ... <- `whisper_vad_segments_from_samples`, main thread in `__cxa_finalize_ranges` <- `exit`).

The gate is closed before exit begins, never inside it: the app closes it as the last statement of `applicationWillTerminate`; the hosted test bundle closes it from an `XCTestObservation` (principal class `TestRunExitDrain`) when the bundle finishes. There is deliberately no `atexit` handler, because draining inside `exit` was tried and crashed: `exit` destroys ggml's function-local statics before any handler registered at launch runs. The app waits at most 3 s, then flushes preferences and calls `_exit(0)` so static destructors never run under a live native call; a test host waits at most 120 s and never force-exits.

| Event | Condition | Transition | Effects |
|---|---|---|---|
| `enter` | `phase == .open`, `inFlight < Int.max` | `inFlight += 1` | `admit` |
| `enter` | `phase == .open`, `inFlight == Int.max` | unchanged | `refuse` |
| `enter` | otherwise | unchanged | `refuse` |
| `leave` | `inFlight > 0`, `phase == .closing`, `inFlight` becomes 0 | `inFlight -= 1`, `phase = .closed` | `drained` |
| `leave` | `inFlight > 0`, otherwise | `inFlight -= 1` | none |
| `leave` | `inFlight == 0` | ignored | none |
| `shutdown` | `phase == .open`, `inFlight == 0` | `phase = .closed` | `drained` |
| `shutdown` | `phase == .open`, `inFlight > 0` | `phase = .closing` | `awaitDrain` |
| `shutdown` | `phase == .closing` | unchanged | `awaitDrain` |
| `shutdown` | `phase == .closed` | unchanged | none |
| `timeout` | `phase == .closing` | `phase = .closed` | `abandon` |
| `timeout` | otherwise | unchanged | none |

Invariants (tested in `ProcessExitGateTests` and `ExitGateCoreTests`): the in-flight count never goes negative; nothing is admitted after shutdown; exactly one of drained or abandon follows a shutdown; drained only at zero in flight; a second shutdown caller waits for the same drain, and on a timeout every waiting caller is released together after the abandon action has run once.

Accepted limits: a host that calls `exit` without either hook is not covered; past the test-host timeout exit proceeds with calls still running; one hosted test bundle is assumed.

The original crash did not reproduce on demand (0 aborts in 45 runs before the change); the opt-in `ExitDuringNativeWorkTests` showed 10 of 10 runs draining before exit with the new design.

## 2 and 3. Recorder (`RecorderCore`)

**Today.** Ownership is `AudioRecordingSessionGate` (a lock). The capture, its URL, two timers and the system-input switch live on a serial queue. `isRecording` and `isConnecting` are published on the main thread. Four clients (capsule, main window, meeting, filter assistant) each keep their own session id and their own idea of the phase.

| Owner phase | Event | Next | Effects |
|---|---|---|---|
| idle | reserve(A) | A opening | open(A) |
| any, owned by X | reserve(A) | unchanged | refuse(A) |
| A opening | opened(A, needs connection) | A connecting | publish, monitorConnection |
| A opening | opened(A) | A live | publish |
| A opening | openFailed(A) | idle | publish, reportStartFailure(A) |
| A connecting | connected(A) | A live | publish |
| A connecting, live | captureEnded(A) | A ended | publish, notifyCaptureEnded(A); audio kept |
| A opening | stop(A) | idle, A detached(finishing) | publish; tail starts when it opens |
| A connecting, live, ended | stop(A) | idle, A detached(finishing) | publish, finishAfterTail(A) |
| A opening | cancel(A) | idle, A detached(discarding) | publish; closed when it opens |
| A connecting, live, ended | cancel(A) | idle | publish, closeAndDiscard(A) |
| A detached(finishing) | tailFinished(A, keep) | removed | resolveStop(A, keep) |
| not owner | stop(B) | unchanged | resolveStop(B, no audio) |
| not owner | cancel(B), connected(B), captureEnded(B) | unchanged | |

Invariants: phase is idle exactly when nobody owns the recorder; audio is discarded only by cancel; every accepted start gets exactly one terminal answer; a capture that ends on its own notifies its owner once and keeps its audio; a stale id never changes another session; the published flags always equal the phase; every opened capture is closed.

Illegal today:
- `audioRecorderDidFinishRecording(successfully: false)` takes ownership away with `take(ifMatching: nil)`, deletes the file, and notifies nobody. Owner state "recording", recorder state "idle, audio gone". The voice-processed path handles the same event correctly (keeps the audio, sends `captureStopped`); the two capture paths disagree.
- `MeetingSessionController` never listens for a capture that ended, so (meeting: recording, recorder: idle) persists until the user stops, and the stop then reports no audio.
- `cancelRecording` uses `workQueue.sync` from the main thread: (main thread blocked, recorder still opening the microphone).

## 4. Trigger gesture (`TriggerCore`)

**Today.** `ShortcutManager` has `activeVm`, `holdMode`, `holdWorkItem`, `pressConsumed`, `pressStartedRecording`, `lastPressDownTime`. `activeVm` mirrors "a dictation is active" and is cleared by a notification when the capsule hides.

Config: hold-to-record, double-press. Input with each event: `capturing` (asked of the session owner).

| Event | Condition | Effects | State |
|---|---|---|---|
| keyDown | double-press on, not capturing, no first tap inside the interval | none | remember first tap |
| keyDown | not capturing | startSession; scheduleHold if hold-to-record | down(started) |
| keyDown | capturing | stopSession | down(not started) |
| holdElapsed | its timer is the outstanding one, press still down | | hold armed |
| keyUp | down, hold armed, hold-to-record, capturing | stopSession | up |
| keyUp | otherwise | | up |
| chord | down(started), capturing | abortSession | up |
| sessionEnded | | | hold disarmed |

Every keyDown, keyUp and chord first cancels the outstanding hold timer.

Invariants: start only when not capturing, stop and abort only when capturing; at most one intent per event; one hold timer at most; hold is armed only for a press that started a session.

Illegal today: (`activeVm` set, session showing "Processing…", "No microphone" or "Recording failed"): the next press calls stop on a session that is not recording and is dropped. Also (`activeVm` set, capture cut short and already transcribing): same.

## 5 and 6. Dictation session (`DictationSessionCore`, planned)

**Today.** `IndicatorViewModel` holds `state` (11 cases), `isConfirmingCancel`, `isFinalizing`, `recorderSessionID`, `dictationGeneration`, `isDeliveryCancelled`, `isCaptureCutShort`, `liveTranscription`, `hideTimer`, `confirmCancelTimer`. `ContentViewModel` holds a second copy for the in-window record button (`state`, `recorderSessionID`, `recordingStartedAt`, `liveTranscription`) and a second implementation of stop, transcribe, clean up and save. `IndicatorWindowManager.viewModel` and `LatestDictationGate` hold the rest.

Explicit model (one session):

| Phase | Event | Next | Effects |
|---|---|---|---|
| idle | start, meeting or queue or engine busy | notice(busy) | scheduleDismiss |
| idle | start, no microphone | notice(noMicrophone) | scheduleDismiss |
| idle | start accepted by recorder | capturing(optimistic) | retire older deliveries |
| capturing | recorder connecting | capturing(connecting) | |
| capturing | recorder live | capturing(live) | |
| capturing | start failed | notice(recordingFailed) | scheduleDismiss |
| capturing(live), past 10 s | cancel requested, confirmation on | capturing(live, confirming) | scheduleConfirmTimeout |
| capturing | cancel (confirmed or not needed) | finished | cancelRecorder, hide |
| capturing | stop, or capture ended on its own | processing(stopping) | stopRecorder |
| processing(stopping) | no audio | finished, or notice(cutShort) | hide |
| processing(stopping) | audio | processing(transcribing) | transcribe |
| processing(transcribing) | text | processing(refining) | refine |
| processing(transcribing) | empty | finished | discard, hide |
| processing(transcribing) | failed | notice(transcriptionFailed) if still newest | keepAudio |
| processing(refining) | text, newest and not cancelled | delivering | save, deliver |
| processing(refining) | text, stale or cancelled | finished | save only |
| processing(any) | cancel | processing(same, delivery cancelled) | hide |
| delivering | paste failed | notice(pasteFailed or clipboardFailed) | scheduleDismiss |
| notice | dismiss timeout | finished | hide |

Illegal today:
- (window dock "Ready to dictate", hotkey dictation capturing): two owners of one fact (finding 5).
- (`isConfirmingCancel`, state not recording) and (`isFinalizing`, state not decoding) are representable; nothing prevents them.
- (state recording, no recorder session): reachable after the recorder failure in finding 2.

Finding 6, the three timing windows after a stop. A new press:
- inside the 0.25 s stop tail: recording starts, the older dictation is retired (History only);
- while the older one is in speech recognition: refused with "Processing…", the new speech is not recorded;
- while the older one is in cleanup: recording starts, the older dictation is retired (History only).
"The newest dictation is the one pasted" is a deliberate, tested policy (`LatestDictationDeliveryTests`), so this is recorded, not changed. Recommendation: deliver every stopped dictation, in stop order, and never refuse a recording because a previous dictation is still processing.

**Lost on process death (finding 8), fixed.** A live dictation is still written to History only in `IndicatorViewModel.finishDictation`, after transcription, cleanup and paste, so a quit, crash or force quit before then leaves only the temporary `<UUID>.wav` file. Launch recovery in `TranscriptionQueue` reads pending rows only, and `AudioRecorder.sweepTemporaryRecordings` deletes unreferenced temporary files once they are 24 hours old. Meetings (before `MeetingSessionController.stop` queues them) and filter-assistant voice input are written by the same recorder to the same folder under the same `<UUID>.wav` names.

Launch now adopts that audio before the sweep runs (`RecordingRecovery.adoptOrphansAtLaunch`, called from `applicationDidFinishLaunching`). The decision is the pure `RecordingRecoveryCore.filesToAdopt` in `DictationCore`; the runner only reads the folder, asks History what it references, and adds the rows.

| Fact about a file in the temporary folder | Adopted | Left in place because |
|---|---|---|
| name | is `<UUID>.wav` | the recorder did not write it |
| History or queue reference | none | a row already owns it |
| last modified | before this process launched | this process may still be writing it, or the date is unknown |
| audio duration | at least 0.35 s (`AudioRecorder.minimumRecordingDuration`) | it is too short to be a recording, or is not readable audio |

Each adopted file becomes a failed row through `RecordingStore.addFailedDictation`, dated with the file's modification date, with the message "Recovered recording - WorkFlow closed before this was transcribed. Select Regenerate to transcribe it." under the usual "Transcription failed" title. Its audio moves into History the way every failed dictation's does, so play, Regenerate, delete and retention treat it like any other failed row. Nothing is transcribed, pasted or copied until the user chooses Regenerate, which uses the cleanup filter that was selected at the launch that recovered it. A recovered meeting or filter-assistant recording cannot be told apart from a dictation by its file, so it is recovered as a dictation row too.

Invariants (tested in `RecordingRecoveryTests` and `RecordingRecoveryCoreTests`):
- The pass never deletes a file. A file it does not adopt is not moved, rewritten or redated, and the 24-hour sweep remains the only thing that removes it.
- The whole pass is skipped while another WorkFlow process runs, because every WorkFlow build shares the folder and an unreferenced file may be one the other process is still transcribing. "Another WorkFlow" is a running application, other than this process, whose bundle identifier is this build's, `com.picturesuo.WorkFlow`, or a legacy identity (`RecordingRecovery.isAnotherWorkFlowRunning`).
- If History cannot say what it references, or cannot save the row, nothing is adopted: a failed save puts the audio back where it was found, for the next launch and the sweep.
- A second pass adopts nothing: adopted audio has left the folder, or is referenced by its row when it could not move.
- Deleting a History row also deletes its audio that is still in the temporary folder (a queued row, or audio kept there after a failed move), so launch recovery never brings back a recording the user deleted (`testDeletingARowDeletesItsTemporaryAudioSoItIsNeverRecovered`).

Two cases were already recovered and still are: queued imports, and dictations stopped while the engine was busy, because both get a pending row at stop through `TranscriptionQueue.addFileToQueue`.

Limits, by decision:
- A recording whose process died while it was still capturing is not recovered. The recorder fills in the WAV header's sizes only when it stops (see `GrowingWAVReader`), and a file whose sizes were never written does not open as audio, so it is left for the sweep (`testFilesThatAreNotOrphanedRecordingsAreLeftUntouched` covers a header with zeroed sizes; a real killed capture was not reproduced). Recovering it would mean reading the samples past the header, as `GrowingWAVReader` does.
- A recording the user meant to discard by force-quitting comes back as a recovered row; they delete it from History like any other.
- When a launch skips the pass because another WorkFlow is running, its files wait for the next launch. The sweep still runs on that launch, so a file already older than 24 hours is deleted then, as it was before.

## 7. Transcription queue and engine reservation (suspected only)

`TranscriptionQueue`: `isProcessing`, `currentRecordingId`, `cancelledRecordingIds`, plus each row's database `status`; "regeneration" is inferred from the transcript not being one of two sentinel strings. `TranscriptionService`: `currentEngine`, `engineLoadTask`, `engineLoadGeneration`, `transcriptionTask`. Both are covered by focused tests and showed up in no crash, trace or benchmark. Not changed.

## History list (`RecordingHistoryModel`)

Already close to explicit (query, generation, offset, loading, canLoadMore). The benchmark had shown the view layer around it, not its state, was the slowest thing a user touches: opening History with 1,200 rows cost 524 ms at the median with a main-thread stall of 250 ms or more on every open, and a search keystroke cost 518 ms beyond the debounce (the before numbers in [perf/baseline.md](perf/baseline.md)). That view and layout work has since been removed without changing how rows look: the window takes a constant-size minimum instead of measuring its tree, search text and the history model are observed separately so typing and paging no longer re-render the whole window, the previous rows stay on screen while a new page loads, and rows are grouped by day once per change.

PR #10's search change scrolled the first result under the pinned day header; it was fixed in PR #12 and is pinned by `HistorySearchScrollTests`. The numbers are in [perf/before-after.md](perf/before-after.md).
