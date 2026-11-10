#!/bin/zsh
# Writes the synthetic known-transcript corpus with offline macOS speech
# synthesis straight to 16 kHz mono 16-bit WAV files. Nothing is played aloud.
# Usage: make-synthetic-corpus.sh <output-folder>
set -euo pipefail
out=${1:?output folder}
mkdir -p "$out"
cd "$out"
fmt=(--data-format=LEI16@16000)
typeset -A refs
mk() { say -v "$2" -o "$1.wav" $fmt "$3"; refs[$1]=$3; }
mk short-command Samantha "Send the report to Maria by Friday."
mk numbers Daniel "The meeting moved to 3:30 on March 14th, and the budget is \$12,500, about 15% over plan."
mk entities "Eddy (English (US))" "Ask Priya Raman to review the Kubernetes migration with Jonathan Okafor before the offsite in Lisbon."
mk punctuation "Flo (English (US))" "Can you check whether the build passed? If it did, merge it. Otherwise, ping me on Slack."
mk pauses Samantha "First, book the flight to Denver. [[slnc 2500]] Then email the hotel and ask about late checkout. [[slnc 4000]] Finally, add it to my calendar."
mk medium Daniel "I looked at the quarterly numbers this morning and I think we need to slow down hiring for the next two months. Revenue is still growing, but the new enterprise deals are taking longer to close than we planned, and support costs went up after the last release."
mk long "Eddy (English (US))" "Here is the plan for next week. On Monday, the design team will finish the onboarding screens and hand them to engineering by noon. On Tuesday, we will run the first usability test with five customers, two from the pilot program and three new ones. Wednesday is reserved for fixing whatever the test uncovers, so please keep that day clear. On Thursday, Sarah will present the results to the leadership group, and we will decide whether the launch stays on the twentieth or moves a week later. Friday is a half day. Before you leave, make sure your tickets are updated, your pull requests are reviewed, and the release notes include every change that a customer could notice. If anything is blocked, tell me as soon as you know, not at the end of the week."
ffmpeg -loglevel error -y -f lavfi -i "anullsrc=r=16000:cl=mono" -t 10 -c:a pcm_s16le silence-10s.wav
ffmpeg -loglevel error -y -f lavfi -i "anoisesrc=r=16000:c=pink:a=0.03:seed=7" -t 10 -ac 1 -c:a pcm_s16le noise-10s.wav
refs[silence-10s]=""
refs[noise-10s]=""
python3 -I -c 'import json, sys; it = iter(sys.argv[1:]); json.dump(dict(zip(it, it)), open("refs.json", "w"), indent=1)' "${(@kv)refs}"
shasum -a 256 *.wav
