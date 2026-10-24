#!/usr/bin/env python3
"""Turns profile JSON files (profiles/*.json) into FFmpeg configure flags or a license report.

usage:
  gen-config.py flags  <profile>...     one configure flag per line
  gen-config.py report <profile>...     Markdown license and codec report
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
KINDS = ["demuxers", "muxers", "parsers", "bsfs", "decoders", "encoders", "protocols", "filters", "indevs"]
SINGULAR = {"demuxers": "demuxer", "muxers": "muxer", "parsers": "parser", "bsfs": "bsf",
            "decoders": "decoder", "encoders": "encoder", "protocols": "protocol", "filters": "filter",
            "indevs": "indev"}
ALL_LIBS = ["avutil", "avcodec", "avformat", "avdevice", "avfilter", "swscale", "swresample"]


def load(names):
    merged = {k: [] for k in KINDS}
    merged.update(libraries=[], extra=[], components=[], codecStatus={}, programs=False, names=list(names))
    for name in names:
        profile = json.loads((ROOT / "profiles" / f"{name}.json").read_text())
        ff = profile["ffmpeg"]
        for kind in KINDS:
            merged[kind] += [x for x in ff.get(kind, []) if x not in merged[kind]]
        merged["libraries"] += [x for x in ff.get("libraries", []) if x not in merged["libraries"]]
        merged["extra"] += [x for x in ff.get("extra", []) if x not in merged["extra"]]
        merged["programs"] = merged["programs"] or ff.get("programs", False)
        merged["components"] += [c for c in profile.get("components", []) if c not in merged["components"]]
        merged["codecStatus"].update(profile.get("codecStatus", {}))
    return merged


def flags(m):
    out = ["--disable-everything"]
    out += [f"--disable-{lib}" for lib in ALL_LIBS if lib not in m["libraries"]]
    out += ["--enable-ffmpeg", "--enable-ffprobe", "--disable-ffplay"] if m["programs"] else ["--disable-programs"]
    for kind in KINDS:
        out += [f"--enable-{SINGULAR[kind]}={item}" for item in m[kind]]
    out += m["extra"]
    return out


def report(m):
    lines = [f"# License and codec report ({', '.join(m['names'])})", "", "## Components", ""]
    lines += [f"- {c['name']}: {c['license']}. {c.get('note', '')}".rstrip() for c in m["components"]]
    lines += ["", "## Codec status", "", "| Codec | Status | Note |", "|---|---|---|"]
    lines += [f"| {k} | {v['status']} | {v.get('note', '')} |" for k, v in sorted(m["codecStatus"].items())]
    lines += ["", "## Enabled components", ""]
    for kind in KINDS:
        if m[kind]:
            lines.append(f"- {kind}: {', '.join(m[kind])}")
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("flags", "report"):
        sys.exit(__doc__)
    merged = load(sys.argv[2:])
    print("\n".join(flags(merged)) if sys.argv[1] == "flags" else report(merged))
