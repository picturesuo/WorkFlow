#!/usr/bin/env python3 -I
"""Summarizes a WorkFlow perf run.

Usage: python3 -I report.py <out dir>

Reads <out>/flows.jsonl (signpost intervals, markers and metrics from
PerfFlowBenchmarkTests), <out>/cold_launch.jsonl (cold-launch.sh) and
<out>/environment.json, then prints and writes <out>/summary.md and
<out>/summary.json. The first iteration of every section is a warm-up and
is left out of the statistics. Standard library only.
"""

import json
import math
import os
import sys

SEARCH_DEBOUNCE_MS = 200.0
# Interval endings that are not a completion of the flow they time.
NOT_COMPLETIONS = {"superseded", "not_a_start"}


def read_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def nearest_rank(sorted_values, percentile):
    if not sorted_values:
        return None
    rank = max(1, math.ceil(percentile / 100.0 * len(sorted_values)))
    return sorted_values[rank - 1]


def median(sorted_values):
    if not sorted_values:
        return None
    middle = len(sorted_values) // 2
    if len(sorted_values) % 2:
        return sorted_values[middle]
    return (sorted_values[middle - 1] + sorted_values[middle]) / 2.0


def stats(values):
    ordered = sorted(values)
    return {
        "n": len(ordered),
        "median_ms": median(ordered),
        "p95_ms": nearest_rank(ordered, 95),
        "min_ms": ordered[0] if ordered else None,
        "max_ms": ordered[-1] if ordered else None,
    }


def fmt(value, digits=1):
    if value is None:
        return "-"
    return f"{value:.{digits}f}"


def attribute(rows):
    """Tags each flow line with the section and iteration it ran in."""
    section, index = None, None
    clear_pending = False
    flows, metrics, events, markers = [], [], [], []
    for row in rows:
        if "marker" in row:
            name = row["marker"]
            markers.append(row)
            if name == "iteration":
                section, index = row.get("section"), row.get("index")
            elif name == "search_clear":
                clear_pending = True
            elif name.endswith("_begin"):
                section, index = row.get("section", name[: -len("_begin")]), None
            elif name.endswith("_end"):
                section, index = None, None
            continue
        if "metric" in row:
            metrics.append(row)
            continue
        if "event" in row:
            events.append(row)
            continue
        if "flow" in row:
            flow = row["flow"]
            if flow == "search_keystroke" and clear_pending:
                flow = "search_keystroke_clear"
                clear_pending = False
            flows.append(dict(row, flow=flow, section=section, index=index))
    return flows, metrics, events, markers


def summarize(out_dir):
    rows = read_jsonl(os.path.join(out_dir, "flows.jsonl"))
    flows, metrics, events, _ = attribute(rows)
    cold = read_jsonl(os.path.join(out_dir, "cold_launch.jsonl"))
    environment = {}
    env_path = os.path.join(out_dir, "environment.json")
    if os.path.exists(env_path):
        with open(env_path, encoding="utf-8") as handle:
            environment = json.load(handle)

    groups = {}
    order = []
    for row in flows:
        key = (row["section"] or "(none)", row["flow"])
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(row)

    flow_rows = []
    for key in order:
        section, flow = key
        measured = [r for r in groups[key] if r["index"] not in (None, 0)]
        warmup = [r for r in groups[key] if r["index"] in (None, 0)]
        outcomes = {}
        for r in measured:
            outcomes[r["outcome"]] = outcomes.get(r["outcome"], 0) + 1
        values = [float(r["ms"]) for r in measured if r["outcome"] not in NOT_COMPLETIONS]
        entry = {"section": section, "flow": flow, "warmup_dropped": len(warmup), "outcomes": outcomes}
        entry.update(stats(values))
        if flow == "search_keystroke":
            entry["minus_debounce"] = stats([v - SEARCH_DEBOUNCE_MS for v in values])
        cpu = [float(r["main_cpu_ms"]) for r in measured
               if r["outcome"] not in NOT_COMPLETIONS and r.get("main_cpu_ms") is not None]
        if cpu:
            entry["main_cpu_ms"] = stats(cpu)
        flow_rows.append(entry)

    # Main-thread CPU of the scroll section, one metric line per iteration.
    scroll_cpu = [float(m["value"]) for m in metrics
                  if m.get("metric") == "main_cpu_ms" and m.get("section") == "history_scroll"
                  and m.get("iteration") not in (None, 0)]
    scroll_cpu_row = None
    if scroll_cpu:
        scroll_cpu_row = {"section": "history_scroll", "metric": "main_cpu_ms"}
        scroll_cpu_row.update(stats(scroll_cpu))

    cold_rows = []
    measured_cold = [r for r in cold if not r.get("warmup") and "launch_ready_ms" in r]
    for name in ["launch_ready_ms", "launch_window_appeared_ms", "engine_ready_ms"]:
        values = [float(r[name]) for r in measured_cold if r.get(name) is not None]
        if values:
            entry = {"metric": name}
            entry.update(stats(values))
            cold_rows.append(entry)
    cold_notes = [r for r in cold if "note" in r]

    hangs = [m for m in metrics if m.get("metric") == "hangs_over_250ms"]
    hitches = [m for m in metrics if m.get("metric") == "hitch_ratio_ms_per_s"]
    other = [m for m in metrics if m.get("metric") not in ("hangs_over_250ms", "hitch_ratio_ms_per_s", "main_cpu_ms")]
    host_events = [e for e in events if "ms_since_process_start" in e]

    summary = {
        "label": environment.get("label"),
        "flows": flow_rows,
        "history_scroll_main_cpu_ms": scroll_cpu_row,
        "cold_launch": cold_rows,
        "cold_launch_notes": cold_notes,
        "hangs": hangs,
        "hitch_ratio": hitches,
        "other_metrics": other,
        "test_host_events": host_events,
        "environment": environment,
    }

    lines = []
    lines.append(f"# WorkFlow perf summary: {environment.get('label', '')}".rstrip())
    lines.append("")
    lines.append("First iteration of each section dropped as warm-up. p95 is nearest-rank. "
                 "Timing columns leave out `superseded` and `not_a_start` endings; outcome counts include them.")
    lines.append("")
    lines.append("## Flows")
    lines.append("")
    lines.append("`main_cpu_ms` is CPU time the main thread used inside the interval, measured only when the "
                 "interval began and ended on the main thread.")
    lines.append("")
    lines.append("| section | flow | n | median ms | p95 ms | min ms | max ms | main_cpu_ms median | main_cpu_ms p95 | outcomes |")
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
    for r in flow_rows:
        outcomes = ", ".join(f"{k} {v}" for k, v in sorted(r["outcomes"].items()))
        cpu = r.get("main_cpu_ms") or {}
        lines.append(f"| {r['section']} | {r['flow']} | {r['n']} | {fmt(r['median_ms'])} | {fmt(r['p95_ms'])} | "
                     f"{fmt(r['min_ms'])} | {fmt(r['max_ms'])} | {fmt(cpu.get('median_ms'))} | {fmt(cpu.get('p95_ms'))} | "
                     f"{outcomes} |")
        if "minus_debounce" in r:
            d = r["minus_debounce"]
            lines.append(f"| {r['section']} | search_keystroke minus {int(SEARCH_DEBOUNCE_MS)} ms debounce | {d['n']} | "
                         f"{fmt(d['median_ms'])} | {fmt(d['p95_ms'])} | {fmt(d['min_ms'])} | {fmt(d['max_ms'])} | - | - | |")
    if scroll_cpu_row:
        c = scroll_cpu_row
        lines.append(f"| history_scroll | main_cpu_ms (2 s scroll) | {c['n']} | {fmt(c['median_ms'])} | {fmt(c['p95_ms'])} | "
                     f"{fmt(c['min_ms'])} | {fmt(c['max_ms'])} | {fmt(c['median_ms'])} | {fmt(c['p95_ms'])} | |")
    lines.append("")
    lines.append("## Cold launch")
    lines.append("")
    if cold_rows:
        lines.append("Standalone Release app, launched in the background; ms from process start (kernel start time).")
        lines.append("")
        lines.append("| metric | n | median ms | p95 ms | min ms | max ms |")
        lines.append("|---|---:|---:|---:|---:|---:|")
        for r in cold_rows:
            lines.append(f"| {r['metric']} | {r['n']} | {fmt(r['median_ms'])} | {fmt(r['p95_ms'])} | "
                         f"{fmt(r['min_ms'])} | {fmt(r['max_ms'])} |")
    else:
        lines.append("Not measured.")
    for note in cold_notes:
        lines.append("")
        lines.append(f"Note: {note['note']}")
    lines.append("")
    lines.append("## Main-thread hangs >= 250 ms")
    lines.append("")
    lines.append("Watchdog pings the main queue every 10 ms; includes warm-up iterations.")
    lines.append("")
    lines.append("| section | hangs | max stall ms |")
    lines.append("|---|---:|---:|")
    for h in hangs:
        lines.append(f"| {h.get('section')} | {h.get('count')} | {fmt(h.get('max_stall_ms'))} |")
    lines.append("")
    lines.append("## Hitch ratio (History)")
    lines.append("")
    lines.append("Hitch ms per second of the window's display link; includes warm-up iterations.")
    lines.append("")
    lines.append("| section | ms/s | frames | seconds |")
    lines.append("|---|---:|---:|---:|")
    for h in hitches:
        lines.append(f"| {h.get('section')} | {fmt(h.get('value'), 2)} | {h.get('frames')} | {fmt(h.get('duration_s'), 1)} |")
    if other or host_events:
        lines.append("")
        lines.append("## Other measurements")
        lines.append("")
        for m in other:
            lines.append(f"- `{json.dumps(m, sort_keys=True)}`")
        for e in host_events:
            lines.append(f"- test host event {e['event']}: {fmt(e.get('ms_since_process_start'))} ms since the test host started")
    lines.append("")
    lines.append("## Environment")
    lines.append("")
    for key in sorted(environment):
        lines.append(f"- {key}: {environment[key]}")
    lines.append("")

    text = "\n".join(lines)
    with open(os.path.join(out_dir, "summary.md"), "w", encoding="utf-8") as handle:
        handle.write(text)
    with open(os.path.join(out_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
    print(text)


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    summarize(sys.argv[1])


if __name__ == "__main__":
    main()
