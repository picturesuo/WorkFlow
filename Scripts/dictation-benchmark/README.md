# Dictation benchmark

Measures how long the text takes after a dictation stops, and how close the text is to what was said, with the real Parakeet v3 model and WorkFlow's own coordinator. Nothing here uses the microphone, plays audio, calls a cleanup provider, or pastes.

## Corpora

- **Synthetic:** `make-synthetic-corpus.sh <folder>` writes short and long dictations with numbers, names, punctuation and pauses, plus silence and pink noise, using offline macOS speech synthesis. It also writes `refs.json` and prints each file's SHA-256. Synthetic speech is clean and its voices are correlated, so it shows wiring and timing, not real-world accuracy.
- **Real speech:** download LibriSpeech test-clean (CC BY 4.0, <https://www.openslr.org/12>) into its own folder, then run `python3 -I make-librispeech-long.py <LibriSpeech/test-clean> <folder> gapped` for dictations of about 30, 60 and 120 s, with 0.4 s between utterances, or `... continuous` for about 60 s of speech with no pauses between utterances. Keep the audio private; it is not part of this repository.

## Runs

Build the test bundle in Release, since the app is installed in Release, then run one suite against a corpus folder with a per-run bundle identifier:

```bash
WORKFLOW_TEST_BUNDLE_ID="com.picturesuo.WorkFlow.fmtest.bench$$"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build-for-testing \
  -scheme OpenSuperWhisper -configuration Release -derivedDataPath build-bench \
  -clonedSourcePackagesDirPath SourcePackages -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES PRODUCT_BUNDLE_IDENTIFIER="$WORKFLOW_TEST_BUNDLE_ID"
TEST_RUNNER_WF_BENCH_CORPUS=<corpus folder> TEST_RUNNER_WF_BENCH_OUT=<results folder> \
TEST_RUNNER_WF_BENCH_LABEL=<name> TEST_RUNNER_WF_BENCH_ITERATIONS=3 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test-without-building \
  -scheme OpenSuperWhisper -configuration Release -derivedDataPath build-bench \
  -clonedSourcePackagesDirPath SourcePackages -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$WORKFLOW_TEST_BUNDLE_ID" \
  -only-testing:OpenSuperWhisperTests/LiveDictationBenchmarkTests
```

The suites skip unless `TEST_RUNNER_WF_BENCH_CORPUS` is set:

- `LiveDictationBenchmarkTests` writes each file into a WAV at real time (`TEST_RUNNER_WF_BENCH_SPEED`, default 1) through AVAudioFile, the recorder's file writer, while the dictation is recognized live, then times `IndicatorViewModel.finishDictation` from the file closing to the delivered text, with cleanup off. The `offline` cell recognizes the same finished file without live recognition. Each row also records the offline text, so live and offline can be compared word for word. The recorder's fixed 0.25 s stop tail comes before the file closes and is not in this clock.
- `LongFormPathComparisonTests` recognizes each file through FluidAudio's batch long-form path (`batch`), its sliding window (`sliding`), and WorkFlow's segmented path (`segmented`), chosen with `TEST_RUNNER_WF_BENCH_VARIANTS`.
- `DictationLatencyBenchmarkTests` times the engine call alone, the coordinator's steps, and the read-only device queries made before a recording starts.

## Scores

`python3 -I report.py <refs.json> <results.jsonl> [--label build] ...` prints, per cell, the word error rate with its 95% Wilson interval, substitutions, deletions and insertions, whether the first and last words match, and latency p50 and p95.

Normalization before scoring: lowercase; `$N` reads as "N dollars" and `%` as "percent"; digit grouping commas, ordinal suffixes and the colon in times are removed; other punctuation is dropped; ordinal words become cardinals; and runs of number words become digits. British and American spellings are not merged, so "colour" against "color" counts as an error.
