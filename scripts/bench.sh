#!/bin/bash
# PRF-1: benchmark with stored baselines. Generates a synthetic 2-minute 1080p MKV (cached in build/bench), runs
# BenchmarkTests three times alone on the machine, and compares the medians with Benchmarks/baseline.json (per machine).
# A metric more than 10% worse than the baseline (and worse by more than the measuring noise) fails.
# usage: scripts/bench.sh [--record]      --record stores this machine's numbers as the new baseline (do it on a quiet machine)
source "$(dirname "$0")/lib/common.sh"
cd "$ROOT"
file="$BUILD/bench/hq-1080p-2min.mkv"; logs="$BUILD/bench"
mkdir -p "$logs"
if [ ! -f "$file" ]; then
  log "make the benchmark file (about 20 s)"
  "$BUILD/tools/bin/ffmpeg" -v error -y -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=120" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=120" \
    -map 0:v -map 1:a -c:v h264_videotoolbox -b:v 20M -maxrate 30M -g 96 -profile:v high -bf 2 -pix_fmt yuv420p -c:a ac3 -b:a 640k -ac 6 -f matroska "$file"
fi
swift build --build-tests > "$logs/build.log" 2>&1 || { tail -20 "$logs/build.log"; die "build failed"; }
runs=()
for i in 1 2 3; do
  log "benchmark run $i of 3"
  MEDIAENGINE_BENCH_FILE="$file" swift test --skip-build --filter BenchmarkTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$logs/run$i.log" || { tail -20 "$logs/run$i.log"; die "benchmark run $i failed (its own targets are asserted)"; }
  runs+=("$logs/run$i.log")
done
python3 -I scripts/bench-compare.py "$@" "${runs[@]}"
