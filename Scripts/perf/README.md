# Flow benchmark

Times WorkFlow's user flows with the app's own `os_signpost` intervals (`OpenSuperWhisper/Utils/PerfSignpost.swift`, subsystem `com.picturesuo.WorkFlow.perf`, category `flow`). They show up in Instruments under os_signpost and Points of Interest in any build. When the environment variable `WF_PERF_OUT` names a file, each ended interval and event is also appended there as a JSON line; without it nothing is written.

## Run

```bash
./run.sh build            # once, for libwhisper and the autocorrect dylib
Scripts/perf/run-benchmark.sh --iterations 12 --label baseline --out <results folder>
```

The script builds Release for testing into `build.noindex/perf-dd` under a per-run bundle id `com.picturesuo.WorkFlow.fmtest.perf<pid>`, so nothing reads WorkFlow's own preferences, History or Keychain. It then runs `PerfFlowBenchmarkTests` hosted in that build, runs `cold-launch.sh`, and writes `summary.md`, `summary.json` and `environment.json` (load average, Mac model, macOS, Xcode, commit) to the results folder.

- `--skip-build` reuses the last build and its bundle id.
- `--skip-launch` skips the cold-launch step.
- `--trace` runs the suite once more with xctrace attached (Time Profiler, Hangs, os_signpost) and saves it as `flows-<date>-<time>.trace` next to the results, so an earlier trace is never deleted or overwritten. The suite waits up to 120 s for the trace to start (`WF_PERF_WAIT_FOR_TRACE=1`).

  Trace files embed the traced process's environment variables, which can include secrets. Never share or commit a .trace bundle.

`python3 -I Scripts/perf/report.py <results folder>` rebuilds the summary from `flows.jsonl` and `cold_launch.jsonl`.

The suite skips unless `TEST_RUNNER_WF_PERF_OUT` is set, so the normal test command is unaffected. `TEST_RUNNER_WF_PERF_ITERATIONS` sets iterations (default 12). The first iteration of each section is a warm-up and is left out of the statistics.

## What the numbers mean

All times are milliseconds on a monotonic clock. p95 is nearest-rank, so with 11 measured iterations it is the slowest one.

| Flow | From | To |
|---|---|---|
| `trigger_to_mic_live` | the shortcut handler is called, before the main-queue hop | the recorder's capture has really begun (`AVAudioRecorder.record()` returned true, or the voice-processing engine started) |
| `trigger_to_indicator_visible` | the same press | the indicator panel is ordered front, after the caret lookup (up to 150 ms) |
| `cancel_after_start` | right after the press reached the main thread | `stopForce()` returned: how long the main thread waits on the recorder's queue to cancel a recording still starting |
| `stop_to_delivered` | `startDecoding()` accepted the stop | delivery returned; ends `queued` or `no_audio` when nothing is delivered |
| `stop_tail` | the recorder stop is requested | it returned, including the fixed 0.25 s tail |
| `finish_dictation` | `finishDictation` entry (the audio file is closed) | delivery returned |
| `transcribe`, `cleanup`, `deliver` | the parts of `finish_dictation` | |
| `history_open` | the History window is ordered in | the first page is assigned and SwiftUI and Core Animation have committed it |
| `search_keystroke` | one search field change | that query's first page is committed; includes the 200 ms debounce by design, so the report also shows it minus 200 ms. `search_keystroke_clear` is clearing the field, which skips the debounce |

- **Hangs >= 250 ms:** a background thread hands the main queue a block every 10 ms and counts the times the main thread took 250 ms or more to run it, with the longest stall, per section.
- **Hitch ratio:** for the History sections, the window's display link (`NSWindow.displayLink`) reports each frame; a frame later than its predecessor's target adds the excess to the hitch time. Reported as hitch milliseconds per second.
- **Cold launch:** process start (the kernel's start time) to `launch_ready` (end of `applicationDidFinishLaunching`), `launch_window_appeared` and `engine_ready` (the speech model loaded), for a Release build opened in the background. One warm-up launch, then 10.

## What is substituted

- **Microphone.** The press flows (`trigger_to_mic_live`, `trigger_to_indicator_visible`, `cancel_after_start`, and `stop_tail`/`stop_to_delivered` from a live stop) need the test host to have microphone access already. The suite only reads `AVCaptureDevice.authorizationStatus`; when it is `notDetermined` it skips those flows rather than raise the system prompt, because each run's bundle id is new to macOS privacy settings. Measuring them needs a stable test identity granted microphone access once by the owner.
- **Speech.** The stop flows use the repository's public-domain `jfk.wav` (11 s) copied to a temporary file and handed to `IndicatorViewModel.finishDictation`, not live speech from the recorder. The fixed 0.25 s stop tail is therefore not in `finish_dictation`.
- **Paste.** Delivery runs the app's real pasteboard code on a private named pasteboard, and the Cmd+V keystroke is replaced by a stub that reports success. The general pasteboard is never written and no keystroke is posted.
- **Cloud cleanup.** `stop_cloud_stub` uses the production OpenAI provider code with a placeholder key, answered in process by a URLProtocol fixture that returns the transcript unchanged with no added latency. Real provider latency is not included.
- **Windows.** The History window and the indicator panel are alpha 0 and ignore the mouse, and the app never activates, so the owner sees nothing. The compositor may treat an invisible window differently from a visible one, which affects the hitch ratio most.
- **History.** 1,200 synthetic dictations from a fixed seed in a temporary on-disk database, about 80% with dictation evidence, no audio files.
- **Cold launch.** The disk cache is warm after the first launch, so "cold" means a new process, not a cold disk. The launch is currently blocked: `applicationDidFinishLaunching` always runs the legacy credential migration, whose Keychain service names are fixed to `com.picturesuo.WorkFlow.*` whatever the bundle id, so even a perf build would query the owner's real WorkFlow Keychain items. `cold-launch.sh` refuses to launch unless `WF_PERF_ALLOW_STANDALONE_LAUNCH=1`, to be set only once that read is gone. A standalone launch also puts a status item in the menu bar while it runs.
- **Load.** Numbers depend heavily on what else the Mac is doing; `environment.json` records the load average before and after.

## Field numbers from the installed app

macOS does not keep these signposts in the stored log, so either run `Scripts/perf/field-report.sh --watch 600` while dictating (it streams the live log for that many seconds, then reports), or launch the app with `WF_PERF_OUT=<file>` in its environment and read the JSON lines.
`field-report.sh --last DURATION` (default `1h`) reads the stored log instead, for whatever macOS happened to keep.
It pairs each interval's begin and end per process and prints one row per flow and outcome code, plus the `launch_ready`, `launch_window_appeared` and `engine_ready` events, with n, median, p95 (nearest rank), min and max in milliseconds.
This is where `trigger_to_mic_live`, `trigger_to_indicator_visible` and cold launch come from, since the benchmark cannot measure them.
It prints only signpost names, outcome codes, counts and durations.
