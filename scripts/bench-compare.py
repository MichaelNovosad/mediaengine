#!/usr/bin/env python3
"""Turns the BENCH lines of Tests/MediaEngineTests/BenchmarkTests.swift into numbers and compares them with the stored baseline
of this machine (Benchmarks/baseline.json). Called by scripts/bench.sh (PRF-1).

usage: bench-compare.py [--record] run1.log [run2.log ...]    (median over the runs; lower is better for every metric)
"""
import json
import pathlib
import re
import statistics
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE = ROOT / "Benchmarks/baseline.json"
TOLERANCE = 0.10                     # a regression over 10% fails (PRF-1) ...
FLOOR = {"ms": 8.0, "MB": 6.0}       # ... unless it is smaller than the measuring noise (milliseconds, megabytes)

PATTERNS = [
    ("probe", "ms", r"BENCH probe: ([\d.]+) ms"),
    ("session plan", "ms", r"session \(index \+ plan\): ([\d.]+) ms"),
    ("first requests", "ms", r"BENCH first requests: total ([\d.]+) ms"),
    ("seek video segment (median)", "ms", r"BENCH seek, video segment: median ([\d.]+) ms"),
    ("sequential per segment (median)", "ms", r"BENCH sequential, all streams per segment: median ([\d.]+) ms"),
    ("memory growth", "MB", r"BENCH memory: baseline \d+ MB, peak \d+ MB, growth (\d+) MB"),
    ("AVPlayer time to playing", "ms", r"BENCH AVPlayer: time to playing ([\d.]+) ms"),
    ("AVPlayer seek to playing (median)", "ms", r"seek to resumed playback: median ([\d.]+) ms"),
]


def machine():
    def sysctl(key):
        return subprocess.run(["sysctl", "-n", key], capture_output=True, text=True).stdout.strip()
    return f"{sysctl('hw.model')} / {sysctl('machdep.cpu.brand_string')} / {sysctl('hw.memsize')}"


def measure(logs):
    runs = []
    for log in logs:
        text = pathlib.Path(log).read_text()
        values = {}
        for name, unit, pattern in PATTERNS:
            match = re.search(pattern, text)
            if match:
                values[name] = float(match.group(1))
        runs.append(values)
    names = [name for name, _, _ in PATTERNS]
    return {name: statistics.median([run[name] for run in runs if name in run]) for name in names if any(name in run for run in runs)}


def main():
    args = sys.argv[1:]
    record = "--record" in args
    logs = [a for a in args if not a.startswith("--")]
    metrics = measure(logs)
    if len(metrics) < len(PATTERNS):
        sys.exit(f"the benchmark printed only {sorted(metrics)}; expected {[p[0] for p in PATTERNS]}")
    units = {name: unit for name, unit, _ in PATTERNS}
    stored = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    key = machine()
    if record:
        stored[key] = {"metrics": metrics, "runs": len(logs), "note": "synthetic 2-minute 1080p file, see scripts/bench.sh"}
        BASELINE.write_text(json.dumps(stored, indent=2, sort_keys=True) + "\n")
        print(f"baseline recorded for {key}")
        for name, value in metrics.items():
            print(f"  {name}: {value:g} {units[name]}")
        return
    if key not in stored:
        print(f"no baseline for this machine ({key}); run scripts/bench.sh --record to store one")
        for name, value in metrics.items():
            print(f"  {name}: {value:g} {units[name]}")
        return
    baseline = stored[key]["metrics"]
    failed = False
    for name, value in metrics.items():
        base = baseline.get(name)
        if base is None:
            continue
        limit = base * (1 + TOLERANCE)
        regression = value > limit and (value - base) > FLOOR[units[name]]
        failed = failed or regression
        print(f"  {'REGRESSION' if regression else 'ok        '} {name}: {value:g} {units[name]} (baseline {base:g}, limit {limit:g})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
