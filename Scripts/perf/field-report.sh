#!/bin/zsh
# Prints WorkFlow's perf signpost durations from this Mac's unified log.
# Usage: Scripts/perf/field-report.sh [--last DURATION]   (default 1h, any `log show --last` value)
# Only signpost names, outcome codes, counts and durations are printed, never other log content.
set -euo pipefail

duration="1h"
while (( $# > 0 )); do
    case "$1" in
        --last)
            (( $# >= 2 )) || { print -u2 "usage: $0 [--last DURATION]"; exit 2; }
            duration="$2"
            shift 2
            ;;
        -h|--help)
            print "usage: $0 [--last DURATION]"
            exit 0
            ;;
        *)
            print -u2 "usage: $0 [--last DURATION]"
            exit 2
            ;;
    esac
done

# zsh has a `log` builtin, so call the system tool by path.
/usr/bin/log show --last "$duration" --signpost --style ndjson \
    --predicate 'subsystem == "com.picturesuo.WorkFlow.perf"' |
python3 -I -c '
import ctypes
import json
import math
import re
import sys


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


timebase = Timebase()
ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(timebase))
ms_per_tick = timebase.numer / timebase.denom / 1e6

EVENT = re.compile(r"^([A-Za-z0-9_]+) (-?[0-9]+(?:\.[0-9]+)?)ms$")
OUTCOME = re.compile(r"^[A-Za-z0-9_]+$")

begins = {}
rows = {}

for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if entry.get("eventType") != "signpostEvent":
        continue
    kind = entry.get("signpostType")
    name = entry.get("signpostName") or ""
    if not OUTCOME.match(name):
        continue
    if kind == "event" and name == "event":
        match = EVENT.match((entry.get("eventMessage") or "").strip())
        if match and float(match.group(2)) >= 0:
            rows.setdefault(match.group(1), []).append(float(match.group(2)))
        continue
    key = (entry.get("processID"), name, entry.get("signpostID"))
    stamp = entry.get("machTimestamp")
    if not isinstance(stamp, int):
        continue
    if kind == "begin":
        begins[key] = stamp
    elif kind == "end" and key in begins:
        outcome = (entry.get("eventMessage") or "").strip()
        label = name + " " + outcome if OUTCOME.match(outcome) else name + " (other)"
        rows.setdefault(label, []).append((stamp - begins.pop(key)) * ms_per_tick)


def median(values):
    middle = len(values) // 2
    return values[middle] if len(values) % 2 else (values[middle - 1] + values[middle]) / 2


if not rows:
    print("No WorkFlow perf signposts in this window.")
    sys.exit(0)

width = max(len("name"), *(len(label) for label in rows))
print("name".ljust(width), "n".rjust(5), "median ms".rjust(10), "p95 ms".rjust(10), "min".rjust(10), "max".rjust(10), sep="  ")
for label in sorted(rows):
    values = sorted(rows[label])
    p95 = values[max(0, math.ceil(0.95 * len(values)) - 1)]
    print(f"{label:<{width}}  {len(values):>5}  {median(values):>10.1f}  {p95:>10.1f}  {values[0]:>10.1f}  {values[-1]:>10.1f}")
'
