"""Summarizes benchmark JSON lines: word error rate against refs.json and
latency percentiles, per measured cell.

Usage: python3 -I report.py <refs.json> <results.jsonl>... [--label NAME]...
Each results file may come from any DictationLatencyBenchmarkTests,
LongFormPathComparisonTests or LiveDictationBenchmarkTests run; a --label
after a file prefixes its cells, so two builds can be compared side by side.
"""
import collections, json, math, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import score  # noqa: E402

args = sys.argv[1:]
refs = json.load(open(args.pop(0)))
inputs, labels = [], {}
while args:
    item = args.pop(0)
    if item == "--label":
        labels[inputs[-1]] = args.pop(0)
    else:
        inputs.append(item)

cells = collections.defaultdict(list)
for path in inputs:
    for line in open(path):
        row = json.loads(line)
        if row.get("fixture") not in refs:
            continue
        cell = row.get("path") or row.get("cell")
        if path in labels:
            cell = f"{labels[path]}:{cell}"
        seconds = next((row[k] for k in ("closeToDeliveredSeconds", "seconds", "wallSeconds") if k in row), None)
        cells[cell].append((refs[row["fixture"]], row["text"], seconds))


def percentile(values, q):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(q * len(ordered)) - 1))]


for cell, rows in sorted(cells.items()):
    s = score([(ref, hyp) for ref, hyp, _ in rows])
    times = [t for _, _, t in rows if t is not None]
    timing = (f"latency p50 {1000 * percentile(times, 0.5):.0f} ms p95 {1000 * percentile(times, 0.95):.0f} ms"
              if times else "")
    print(f"{cell:28} n {s['utts']:4} words {s['words']:6} S {s['S']:4} D {s['D']:4} I {s['I']:4} "
          f"WER {100 * s['wer']:.2f}% (95% {100 * s['wer95'][0]:.2f}-{100 * s['wer95'][1]:.2f}%) "
          f"first {s['first_ok']}/{s['utts']} last {s['last_ok']}/{s['utts']} {timing}")
