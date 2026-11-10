#!/bin/zsh
# Runs WorkFlow's flow benchmark end to end: a Release build for testing under
# a per-run fmtest.perf bundle id, PerfFlowBenchmarkTests, the cold-launch
# timing, and the report. See Scripts/perf/README.md.
#
# Usage: run-benchmark.sh [--iterations N] [--out DIR] [--label NAME] [--trace]
#                         [--skip-build] [--skip-launch]
set -euo pipefail

ROOT=${0:A:h:h:h}
cd "$ROOT"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

iterations=12
out="$ROOT/build/perf-results/$(date +%Y%m%d-%H%M%S)"
label=run
trace=false
skip_build=false
skip_launch=false
while (( $# )); do
    case $1 in
        --iterations) iterations=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --label) label=$2; shift 2 ;;
        --trace) trace=true; shift ;;
        --skip-build) skip_build=true; shift ;;
        --skip-launch) skip_launch=true; shift ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) print -u2 "unknown option $1"; exit 2 ;;
    esac
done
mkdir -p "$out"
out=${out:A}

DD="$ROOT/build/perf-dd"
APP="$DD/Build/Products/Release/WorkFlow.app"
common=(-scheme OpenSuperWhisper -configuration Release -derivedDataPath "$DD"
        -clonedSourcePackagesDirPath SourcePackages -destination 'platform=macOS,arch=arm64'
        CODE_SIGNING_ALLOWED=NO)

if [[ ! -f build/libautocorrect_swift.dylib || ! -d libwhisper/build ]]; then
    print -u2 "Native dependencies are missing. Run ./run.sh build once from $ROOT, then retry."
    exit 1
fi
if pgrep -f "xcodebuild.*-derivedDataPath $DD" >/dev/null; then
    print -u2 "Another xcodebuild is using $DD; wait for it to finish."
    exit 1
fi

if $skip_build; then
    [[ -d $APP ]] || { print -u2 "No build at $APP; run without --skip-build first."; exit 1; }
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
else
    bundle_id="com.picturesuo.WorkFlow.fmtest.perf$$"
    print "Building Release for testing as $bundle_id ..."
    xcodebuild build-for-testing "${common[@]}" ENABLE_TESTABILITY=YES \
        PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" > "$out/build.log" 2>&1 || {
        tail -40 "$out/build.log"; exit 1; }
fi
if [[ $bundle_id != com.picturesuo.WorkFlow.fmtest.perf* ]]; then
    print -u2 "Refusing to run a build whose bundle id is $bundle_id"
    exit 1
fi

python3 -I - "$out/environment.json" "$label" "$bundle_id" "$iterations" <<'PY'
import json, platform, subprocess, sys
path, label, bundle_id, iterations = sys.argv[1:5]
def run(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()
    except Exception as error:
        return f"unavailable ({error})"
env = {
    "label": label,
    "configuration": "Release (build-for-testing, ENABLE_TESTABILITY=YES, CODE_SIGNING_ALLOWED=NO)",
    "bundle_id": bundle_id,
    "iterations": int(iterations),
    "uptime_before": run("uptime"),
    "hw_model": run("sysctl", "-n", "hw.model"),
    "cpu": run("sysctl", "-n", "machdep.cpu.brand_string"),
    "memory_bytes": run("sysctl", "-n", "hw.memsize"),
    "macos": run("sw_vers", "-productVersion") + " (" + run("sw_vers", "-buildVersion") + ")",
    "xcode": " ".join(run("xcodebuild", "-version").split()),
    "git_commit": run("git", "rev-parse", "HEAD"),
    "git_dirty": run("git", "status", "--porcelain") != "",
}
json.dump(env, open(path, "w"), indent=2, sort_keys=True)
PY

run_suite() {
    local flows=$1 log=$2
    shift 2
    env TEST_RUNNER_WF_PERF_OUT="$flows" TEST_RUNNER_WF_PERF_ITERATIONS="$iterations" "$@" \
        xcodebuild test-without-building "${common[@]}" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
        -only-testing:OpenSuperWhisperTests/PerfFlowBenchmarkTests > "$log" 2>&1
}

print "Running PerfFlowBenchmarkTests ($iterations iterations) ..."
rm -f "$out/flows.jsonl"
suite_status=0
run_suite "$out/flows.jsonl" "$out/test.log" || suite_status=$?
grep -E "^Test Case .*(passed|failed|skipped)|error:|Skipped|skipped" "$out/test.log" | sed -n '1,60p' || true

rm -f "$out/cold_launch.jsonl"
if $skip_launch; then
    print -r -- '{"note": "Cold launch skipped (--skip-launch)."}' > "$out/cold_launch.jsonl"
else
    print "Timing cold launch ..."
    "$ROOT/Scripts/perf/cold-launch.sh" "$APP" "$bundle_id" "$out/cold_launch.jsonl" 10 || \
        print -u2 "cold-launch.sh exited with $?; see the note in the summary."
fi

if $trace; then
    print "Recording a trace (time-boxed) ..."
    # Fresh names per run, so --trace never deletes or overwrites an earlier one.
    stamp=$(date +%Y%m%d-%H%M%S)
    trace_flows="$out/trace-flows-$stamp.jsonl"
    trace_file="$out/flows-$stamp.trace"
    run_suite "$trace_flows" "$out/trace-test-$stamp.log" TEST_RUNNER_WF_PERF_WAIT_FOR_TRACE=1 &
    suite_pid=$!
    deadline=$(( SECONDS + 600 ))
    while [[ ! -s $trace_flows.pid ]] && (( SECONDS < deadline )); do sleep 1; done
    if [[ -s $trace_flows.pid ]]; then
        host_pid=$(<"$trace_flows.pid")
        xcrun xctrace record --template 'Time Profiler' --instrument 'Hangs' --instrument 'os_signpost' \
            --attach "$host_pid" --output "$trace_file" --time-limit 20m > "$out/xctrace.log" 2>&1 &
        trace_pid=$!
        sleep 15
        touch "$trace_flows.go"
        wait $suite_pid || print -u2 "The traced suite exited with $?"
        kill -INT $trace_pid 2>/dev/null || true
        wait $trace_pid || print -u2 "xctrace exited with $?; see $out/xctrace.log"
    else
        print -u2 "The traced suite never published its pid; trace skipped."
        kill $suite_pid 2>/dev/null || true
    fi
fi

python3 -I -c 'import json,subprocess,sys; p=sys.argv[1]; e=json.load(open(p)); e["uptime_after"]=subprocess.run(["uptime"],capture_output=True,text=True).stdout.strip(); json.dump(e,open(p,"w"),indent=2,sort_keys=True)' "$out/environment.json"
python3 -I "$ROOT/Scripts/perf/report.py" "$out"
print "\nResults in $out"
exit $suite_status
