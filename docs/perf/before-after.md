# Before and after

This page lists each user-facing flow, measured before and after the changes merged in PRs #8 to #14. All numbers come from the same MacBook Air M1 with 16 GB, measured between 2026-11-09 and 2026-11-10.

- **First** is `4fc7848` plus signposts, as it was installed then. It carried code-coverage instrumentation, because the scheme turned coverage on for every build. Its numbers come from `docs/perf/baseline.md`.
- **Middle** is `25502c3`. Instrumentation is removed, and nothing else changed in these flows.
- **Now** is `4a73408`.

PR #14 (process exit) merged afterwards and does not touch these flows.

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
- **PR #9, idle indicator and instrumentation.** Before it, the installed app had been observed at 26 to 29 percent CPU while idle after a dictation (2026-11-09, `top` on the installed app). The indicator wave no longer renders after the pill hides. `IndicatorIdleCostTests` pins this. The same PR removed code-coverage instrumentation from every build. The installed binary went from about 28.7 MB to 22.8 MB (22,758,352 bytes on the final build). History open went from 524 ms (first) to 254 ms (middle), but those two were measured on different days.
- **PR #10, History.** The window got a constant minimum size. The list stays on screen while a search loads. Observation is narrower. The first page is read before layout. Per-row work is done once. A same-session A/B of this change alone, with both sides instrumented, gave these main-thread CPU medians: open 190.4 to 112.5 ms, keystroke 185.5 to 53.7 ms. Keystroke wall time beyond the debounce went from 179.4 to 48.4 ms.
- **PR #11, ggml Metal heartbeat.** The heartbeat thread used to poll every 5 ms. It now blocks while idle. Context switches per 5 s went from 813.5 to 4.0.
- **PR #12, UI fixes and the search scroll position.** PR #10 had introduced a regression: the first search result was hidden under the pinned day header. This PR fixed it, and `HistorySearchScrollTests` pins the fix.
- **PR #13, main-window polish.** No performance claim.
- **PR #14, process exit.** No performance claim. Quitting now waits up to 3 s for speech-library calls that are still running, instead of risking a crash while the process exits.

## Cold launch

Earlier runs of the installed app gave a `launch_ready` median and p95 of 419.0 / 489.0 ms on the first build (instrumented) and 408.7 / 550.3 ms on the middle build. Three runs on the same final build gave medians of 469.6, 955.7 and 861.2 ms. The build was the same in all three, so the spread comes from the machine (load and swap), not the code. Runs taken at different times cannot be compared, so this page makes no claim either way.

One run (469.6 against 408.7) could mean that launch got about 60 ms slower after PR #10. That is unproven. Two things would settle it: alternating two builds back to back on a quiet machine, or adding signposts inside launch. Today only `launch_ready`, `launch_window_appeared` and `engine_ready` exist.

## Measured and not shipped: adaptive stop tail

The recorder keeps capturing for a fixed 250 ms after the key is released. An adaptive tail would end it early when the audio is already silent. An A/B over 744 clips compared the two. The bar set before the test was 99.5 percent identical text and no lost last word. The final text was identical in 96.9 percent of clips. The last word was lost 7 times and gained 2 times. It was not shipped, because saving up to 250 ms is not worth changing words.

## Process exit

Status: merged in PR #14.

Eight crash reports on 2026-11-09 shared one signature (see `docs/state-machines.md`). The crash did not reproduce on demand (0 of 45 runs). Draining the detectors inside `exit` was tried and rejected: one of 35 runs crashed. The shipped design closes the gate before exit begins. With up to four detectors in flight, 10 of 10 runs drained with no crash report.

## Not measured, and why

- **Trigger key down to microphone live, and cancel right after start.** Test builds have no microphone permission. The signposts exist. They can be read from the installed app with `Scripts/perf/field-report.sh --watch` during a real dictation.
- **The full key-up path including the stop tail (`stop_to_delivered`).** The benchmark hands a recording straight to `finishDictation`, so the recorder stop never runs.
- **A real cloud provider round trip.** The benchmark uses an in-process stub that answers at once.
- **Scroll hitch ratio in the final runs.** The display reported no frames.
- **Idle CPU after a real dictation on the installed app.** This needs a spoken dictation. To check: dictate once, wait 30 s, then run `ps -o %cpu= -p $(pgrep -x WorkFlow)`. It should read near 0.

## Only suspected

- **Cold launch may be about 60 ms slower since PR #10.** See "Cold launch" above. Alternating the two builds back to back on a quiet machine would settle it.
- **Scroll smoothness after PR #10.** In a same-session A/B of PR #10, the scroll hitch ratio was 65.3 ms per s before and 199.5 ms per s after, but one later recheck returned no display frames, so it is unproven either way. Interleaved runs on an awake display would settle it.
- **A data race in ggml's CPU thread pool.** Thread Sanitizer reported it once, when two speech detectors ran at the same time, and whether it is a real race or a false positive is unproven. Repeated Thread Sanitizer runs with two detectors, or a reading of the thread pool's synchronization, would settle it.
- **A GRDB "transaction left open" precondition failure.** It crashed a test host once on 2026-11-10 and did not recur. A reproduction, or a crash report with the open transaction's caller, would settle it.

## Re-running

Run the flows with `Scripts/perf/run-benchmark.sh` and summarize them with `Scripts/perf/report.py`. `Scripts/perf/README.md` explains each number and what is substituted. Compare only interleaved runs from one session.
