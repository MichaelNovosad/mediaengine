---
name: engine-benchmark
description: Measure MediaEngine on a long or high-bitrate file (open time, first segments, seeks, AVPlayer start and seek, memory, audio/video drift) and generate synthetic test files for it. Use for performance work, memory questions, RMX-5/6/7/12 evidence, or when a real MKV from the owner arrives.
---

# Benchmarking

`Tests/MediaEngineTests/BenchmarkTests.swift` runs only when `MEDIAENGINE_BENCH_FILE` names a file. It prints `BENCH ...` lines and asserts the acceptance targets (probe < 500 ms, first requests < 1.5 s, median seek < 500 ms, memory growth < 150 MB, A/V drift < 40 ms, neighbour-segment gaps < 40 ms).

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
MEDIAENGINE_BENCH_FILE=/path/movie.mkv swift test --filter BenchmarkTests 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -E "error:|BENCH|Test run with|Expectation failed|Caught"
```

Extras: `MEDIAENGINE_BENCH_TRACE=1` prints footprint vs cache every 4 segments; `MEDIAENGINE_BENCH_HOLD=1` pauses at the end and prints the pid.

## Synthetic files (scratchpad, not committed)

```bash
FF=build/tools/bin/ffmpeg
# 3 hours, tiny frames, B-frames, AAC + FLAC (about 550 MB, ~4 min to make)
$FF -v error -y -f lavfi -i "testsrc2=size=320x180:rate=24:duration=10800" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=10800" -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=10800" \
  -map 0:v -map 1:a -map 2:a -c:v h264_videotoolbox -b:v 200k -g 96 -profile:v high -bf 2 -pix_fmt yuv420p -c:a:0 aac_at -b:a:0 64k -c:a:1 flac -f matroska three-hours.mkv
# 3 minutes of 1080p at ~13 Mbps with AC-3 5.1 (~280 MB, 30 s)
$FF -v error -y -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=180" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=180" \
  -map 0:v -map 1:a -c:v h264_videotoolbox -b:v 40M -maxrate 60M -g 96 -profile:v high -bf 2 -pix_fmt yuv420p -c:a ac3 -b:a 640k -ac 6 -f matroska hq-1080p.mkv
# 4K at ~44 Mbps (640 MB, 2 min, 1 min to make). -b:v stops at 44 Mbps; -q:v 90 gives ~66 Mbps.
# Do not use -q:v 100: it switches to High 4:4:4 Predictive, which the planner refuses.
$FF -v error -y -f lavfi -i "testsrc2=size=3840x2160:rate=24:duration=120" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=120" -map 0:v -map 1:a \
  -c:v h264_videotoolbox -b:v 120M -maxrate 150M -g 48 -profile:v high -bf 2 -pix_fmt yuv420p -c:a ac3 -b:a 640k -ac 6 -f matroska uhd-44mbps.mkv
```

`MEDIAENGINE_BENCH_SEGMENT_BYTES=9000000000` switches the segment size cap off (old time-only segments) for comparisons.

Baseline (M1 Max; tables in `docs/RESEARCH.md` sections 14 and 15): AVPlayer playing after 464-629 ms, seek until playing 242-393 ms, A/V drift under 1 ms over 3 h, memory growth 65 MB (3 h file), 82 MB (1080p 13 Mbps), 101 MB (4K 44 Mbps), 116 MB (4K 66 Mbps). Compare new runs with those; a regression over 10% needs an explanation.

## Memory lessons

- `phys_footprint` (what jetsam counts) keeps blocks abandoned by growing a `Data` through appends, and keeps freed multi-megabyte `malloc` blocks too. Allocate big buffers at their final size (`ByteWriter(capacity:)`) and put finished multi-megabyte outputs into `BigBuffer.make` (mmap, returned on release).
- `malloc_zone_pressure_relief` did not return that memory; measure with a footprint trace, not guesses. `leaks` and `vmmap` cannot attach from the tool sandbox.
- Segment memory scales with bitrate; segments are therefore also capped by size (24 MB, `SegmentPlan`). A single GOP above the cap is not split.

Phone numbers (RMX-6) need the owner's device; write a short device script instead of guessing.
