#!/bin/bash
# Runs tests over and over and says which fail and how often, so a flaky test gets a measured failure rate instead of a
# guess. Logs of failing runs are kept in build/flake/.
# usage: scripts/flake-hunt.sh <runs> [swift test arguments...]
#   scripts/flake-hunt.sh 20 --filter PlayListPlaybackTests
#   scripts/flake-hunt.sh 10 --skip 'AVPlayerEndToEndTests|...'      (what unit_pass runs; see scripts/lib/tests.sh)
# Do not run anything else on the machine meanwhile: load is what makes timing-sensitive tests fail.
source "$(dirname "$0")/lib/common.sh"
cd "$ROOT"
runs="${1:?usage: scripts/flake-hunt.sh <runs> [swift test arguments...]}"; shift
dir="$BUILD/flake"; rm -rf "$dir"; mkdir -p "$dir"
failed_runs=0
for i in $(seq 1 "$runs"); do
  if swift test "$@" > "$dir/run$i.log" 2>&1; then
    rm "$dir/run$i.log"; printf '.'
  else
    failed_runs=$((failed_runs + 1)); printf 'F'
  fi
done
echo
if [ "$failed_runs" -eq 0 ]; then log "no failure in $runs runs"; exit 0; fi
echo "failed runs: $failed_runs of $runs. Tests that failed (failures per test):"
cat "$dir"/run*.log | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^􀢄  Test "' | grep -E 'recorded an issue|failed after' \
  | sed -E 's/^􀢄  Test "([^"]*)".*/\1/' | sort | uniq -c | sort -rn
echo "logs: $dir"
exit 1
