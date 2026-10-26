#!/bin/bash
# usage: loadrun.sh NPROCS SECONDS RATE
# Starts NPROCS busy-loop processes, runs gsrloop (24 channels) for SECONDS at RATE, then stops exactly the processes it started.
N=$1; T=$2; R=$3
D="$(cd "$(dirname "$0")" && pwd)"
PIDS=""
for i in $(seq 1 "$N"); do
  ( while :; do :; done ) &
  PIDS="$PIDS $!"
done
echo "started $N busy loops; load average: $(uptime | sed 's/.*load averages*: //')"
sleep 3
cd "$D"
./gsrloop --go --upto 24 -l -36 -t "$T" -C 1 -r "$R" > /tmp/gl_load.txt 2>&1
echo "load average at the end: $(uptime | sed 's/.*load averages*: //')"
kill $PIDS 2>/dev/null
wait $PIDS 2>/dev/null
grep -h "s: STATUS\|Level monitor\|pairs\|dropout:\|Playback:\|Capture :\|VERDICT\|Card after\|FAILED" /tmp/gl_load.txt
