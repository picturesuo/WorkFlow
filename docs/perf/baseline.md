# Performance baseline

Measured on 2026-11-09 at commit `4fc7848` plus signposts only (no behavior change), Release build, MacBookAir10,1 (M1, 16 GB), macOS 26.6.2, Xcode 27.2. The machine was busy with other builds during the run (load average 30 before, 109 after), so read the absolute numbers as an upper bound and compare runs only when they are taken back to back.

How it is measured: `Scripts/perf/run-benchmark.sh` runs each flow 12 times inside the real app binary and drops the first iteration as warm-up. Every flow is an `os_signpost` interval (subsystem `com.picturesuo.WorkFlow.perf`), so the same intervals show in Instruments. See `Scripts/perf/README.md` for what each number means.

## What is substituted, and what is not measured

- Speech comes from a fixture file (`jfk.wav`, 11 s), not the microphone. The recorder's fixed 250 ms stop tail happens before the measured part and is added in the table below as a constant.
- Paste goes to a private pasteboard and no Cmd+V is posted, so the target app's own handling is not included.
- "Cloud" is the real OpenAI provider code against an in-process stub that answers at once: it shows WorkFlow's own overhead, not a provider's round trip.
- History renders in a fully transparent window so nothing appears on screen.
- **Not measured: trigger key down until the microphone is live, and cancel right after start.** The test identity has no microphone permission (`not_determined`), and asking would raise a system prompt. The signposts `trigger_to_mic_live` and `trigger_to_indicator_visible` are in the app and are read from the installed app with `Scripts/perf/field-report.sh --watch` or by launching it with `WF_PERF_OUT` set, during real dictations. `cancel_after_start` is a benchmark-only signpost emitted by `PerfFlowBenchmarkTests` (`testCancelRightAfterStart`), measured only when the test host has microphone access; the installed app never emits it, so `field-report.sh` cannot report it.
- **Not measured here: cold launch.** A separately identified build would still query WorkFlow's real Keychain items at launch, so the benchmark refuses to launch one. Cold launch (the `launch_ready` and `engine_ready` signposts) is read from the installed app with `Scripts/perf/field-report.sh --watch` or by launching it with `WF_PERF_OUT` set. Numbers taken that way are in docs/perf/before-after.md.

## Flows (n = 11 each unless noted)

| Flow | Median ms | p95 ms | Min | Max |
|---|---:|---:|---:|---:|
| Key up to text delivered, local model: fixed stop tail | 250 | 250 | 250 | 250 |
| Key up to text delivered, local model: recognize, clean up, save, paste | 341.7 | 456.6 | 301.9 | 456.6 |
| of which speech recognition | 332.8 | 450.1 | 295.5 | 450.1 |
| of which paste | 1.1 | 2.0 | 0.8 | 2.0 |
| Key up to text delivered, cloud cleanup (stubbed provider): after the stop tail | 329.8 | 616.1 | 256.8 | 616.1 |
| of which cleanup pipeline around the provider call | 4.7 | 10.8 | 4.0 | 10.8 |
| Open History with 1,200 entries | 524.1 | 931.7 | 404.0 | 931.7 |
| Search keystroke to results on screen (n = 62) | 718.3 | 929.8 | 418.5 | 957.4 |
| the same minus the 200 ms debounce | 518.3 | 729.8 | 218.5 | 757.4 |
| Clear the search field | 390.8 | 650.1 | 270.3 | 650.1 |

So a key release reaches pasted text in about 590 ms at the median with the local model (250 ms fixed tail plus 342 ms), and the tail is 42 percent of that.

## Hangs and hitches

Main-thread stalls of 250 ms or more, over all 12 iterations:

| Section | Hangs | Longest stall ms |
|---|---:|---:|
| Open History | 12 | 478.4 |
| Scroll History | 0 | 156.9 |
| Search History | 40 | 431.7 |
| Stop, local model | 0 | 12.1 |
| Stop, cloud stub | 0 | 18.9 |

Hitch ratio (milliseconds of late frames per second of display time):

| Section | Hitch ms per s | Frames | Seconds |
|---|---:|---:|---:|
| Open History | 469.8 | 423 | 11.4 |
| Scroll History | 588.1 | 1204 | 24.2 |
| Search History | 686.4 | 2043 | 57.5 |

The hitch ratios were taken on a loaded machine with an invisible window, so they overstate what a user sees; they are for comparing before and after, not for quoting.

## Reading

1. **History is the slowest thing a user touches.** Every open stalls the main thread for a quarter second or more, and each search keystroke costs about half a second beyond the debounce.
2. **The fixed stop tail is the largest single piece of key-up to paste** that WorkFlow controls without changing the speech model.
3. Cleanup, saving and pasting are already small (under 10 ms together).
