# Before and after

This page lists each user-facing flow, measured before and after the changes merged in PRs #8 to #13. All numbers come from the same MacBook Air M1 with 16 GB, measured between 2026-11-09 and 2026-11-10.

- **First** is `4fc7848` plus signposts, as it was installed then. It carried code-coverage instrumentation, because the scheme turned coverage on for every build. Its numbers come from `docs/perf/baseline.md`.
- **Middle** is `25502c3`. Instrumentation is removed, and nothing else changed in these flows.
- **Now** is `4a73408`.

Other builds shared the machine all night. The load average was 8 to 277 during the final runs, so wall-clock times are noisy. Main-thread CPU time is steadier. Ratios are quoted only from interleaved runs in one session: middle and now, two rounds each, 11 samples per round (62 for keystrokes). The first column was measured on a different day. It is context, not a ratio.

## Every flow

Times are in milliseconds unless noted. Middle and now are the pooled medians of both rounds.

| Flow | First | Middle | Now | Verdict |
|---|---|---|---|---|
| Open History with 1,200 entries, wall median / p95 | 524.1 / 931.7 | 254.0 / 304.0 | 181.6 / 236.0 | faster |
| Open History, main-thread CPU median | not recorded | 223.7 | 156.9 | 0.70 of middle |
| Open History, stalls of 250 ms or more per 12 opens | 12 | 0 | 0 | |
| Search keystroke to results, wall median | 718.3 | 378.1 | 271.8 | |
| the same minus the 200 ms debounce | 518.3 | 178.1 | 71.8 | 0.40 of middle |
| Search keystroke, main-thread CPU median | not recorded | 170.9 | 69.7 | 0.41 of middle |
| Clear the search field, wall median | 390.8 | 140.4 | 76.2 | |
| Scroll History for 2 s, main-thread CPU | not recorded | 976.5 | 998.8 | unchanged |
| Scroll smoothness (hitch ratio) | 588.1 ms per s | not measurable | not measurable | the display reported no frames during the final runs |
| Key up to text delivered, local model, after the stop tail | 341.7 | 307.9 | 396.0 | no code change; the two final rounds were 558.7 and 262.3, so no claim |
| Key up to text delivered, stubbed cloud cleanup | 329.8 | 366.2 | 324.0 | no code change; rounds disagree, no claim |
| Fixed stop tail | 250 | 250 | 250 | unchanged, see below |
| Trigger key down until the microphone is live | not measured | not measured | not measured | see "Not measured, and why" |
| Cold launch to `launch_ready`, installed app, median / p95 of 10 | 419.0 / 489.0 (instrumented) | 408.7 / 550.3 | | not comparable, see below |
| Context switches per 5 s while idle after the Whisper engine was used | | 813.5 (before PR #11) | 4.0 (after) | |

## What produced each change

- **PR #8, signposts and harness.** It added the `os_signpost` intervals and `PerfFlowBenchmarkTests`. Behavior did not change.
- **PR #9, idle indicator and instrumentation.** The indicator wave no longer renders after the pill hides. `IndicatorIdleCostTests` pins this. The same PR removed code-coverage instrumentation from every build. History open went from 524 ms (first) to 254 ms (middle), but those two were measured on different days.
- **PR #10, History.** The window got a constant minimum size. The list stays on screen while a search loads. Observation is narrower. The first page is read before layout. Per-row work is done once. A same-session A/B of this change alone, with both sides instrumented, gave these main-thread CPU medians: open 190.4 to 112.5 ms, keystroke 185.5 to 53.7 ms. Keystroke wall time beyond the debounce went from 179.4 to 48.4 ms.
- **PR #11, ggml Metal heartbeat.** The heartbeat thread used to poll every 5 ms. It now blocks while idle. Context switches per 5 s went from 813.5 to 4.0.
- **PR #12, UI fixes and the search scroll position.** PR #10 had introduced a regression: the first search result was hidden under the pinned day header. This PR fixed it, and `HistorySearchScrollTests` pins the fix.
- **PR #13, main-window polish.** No performance claim.

## Cold launch

Earlier runs of the installed app gave a `launch_ready` median and p95 of 419.0 / 489.0 ms on the first build (instrumented) and 408.7 / 550.3 ms on the middle build. Three runs on the same final build gave medians of 469.6, 955.7 and 861.2 ms. The difference came from what else the machine had just done (load and swap). Runs taken at different times cannot be compared, so this page makes no claim either way.

One run (469.6 against 408.7) could mean that launch got about 60 ms slower after PR #10. That is unproven. Two things would settle it: alternating two builds back to back on a quiet machine, or adding signposts inside launch. Today only `launch_ready`, `launch_window_appeared` and `engine_ready` exist.

## Measured and not shipped: adaptive stop tail

The recorder keeps capturing for a fixed 250 ms after the key is released. An adaptive tail would end it early when the audio is already silent. An A/B over 744 clips compared the two. The final text was identical in 96.9 percent of clips. The last word was lost 7 times and gained 2 times. It was not shipped, because saving up to 250 ms is not worth changing words.

## Process exit

Status: in review at the time of writing.

The crash did not reproduce on demand (0 of 45 runs). Draining the detectors inside `exit` was tried and rejected: one run in 10 crashed. The shipped design closes the gate before exit begins. With up to four detectors in flight, 10 of 10 runs drained with no crash report.

## Not measured, and why

- **Trigger key down to microphone live, and cancel right after start.** Test builds have no microphone permission. The signposts exist. They can be read from the installed app with `Scripts/perf/field-report.sh --watch` during a real dictation.
- **The full key-up path including the stop tail (`stop_to_delivered`).** The benchmark hands a recording straight to `finishDictation`, so the recorder stop never runs.
- **A real cloud provider round trip.** The benchmark uses an in-process stub that answers at once.
- **Scroll hitch ratio in the final runs.** The display reported no frames.
- **Idle CPU after a real dictation on the installed app.** This needs a spoken dictation. To check: dictate once, wait 30 s, then run `ps -o %cpu= -p $(pgrep -x WorkFlow)`. It should read near 0.

## Re-running

Run the flows with `Scripts/perf/run-benchmark.sh` and summarize them with `Scripts/perf/report.py`. `Scripts/perf/README.md` explains each number and what is substituted. Compare only interleaved runs from one session.
