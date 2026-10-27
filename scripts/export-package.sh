#!/bin/bash
# Makes a clean, release-shaped copy of the Swift package for an app to depend on by path: Package.swift (no test target), the sources,
# and the three XCFrameworks. Output: dist/package/MediaEngine.
# Why: this repository's build/ folder holds about 100,000 files (sources, intermediates); Xcode lists every file of a path dependency
# and looks up its type, which took an hour at background priority. The copy has a few hundred files. Incremental (rsync): run it
# before every app build; it takes seconds.
# usage: scripts/export-package.sh [core|extended]
# The optional argument is the variant the exported package links by default (MEDIAENGINE_PROFILE still overrides it): `core` for apps
# that play what Apple decodes, `extended` for apps that also want the software decoders and legacy containers. Both frameworks are in
# the copy. Default: core.
source "$(dirname "$0")/lib/common.sh"
profile="${1:-core}"
case "$profile" in core|extended) ;; *) die "usage: scripts/export-package.sh [core|extended]" ;; esac
out="$ROOT/dist/package/MediaEngine"
for f in FFmpegLGPL.xcframework LibASS.xcframework; do [ -d "$BUILD/$f" ] || die "$f is not built (scripts/build-all.sh)"; done
mkdir -p "$out/Frameworks" "$out/Sources"

rsync -a --delete --exclude .DS_Store "$ROOT/Sources/MediaEngine/" "$out/Sources/MediaEngine/"
for f in FFmpegLGPL.xcframework FFmpegLGPL-extended.xcframework LibASS.xcframework; do
  if [ -d "$BUILD/$f" ]; then rsync -a --delete --exclude .DS_Store "$BUILD/$f/" "$out/Frameworks/$f/"; else rm -rf "$out/Frameworks/$f"; fi
done
cp "$ROOT/LICENSE" "$out/LICENSE"

# The manifest: the frameworks live in Frameworks/, and the test target stays behind.
python3 -I - "$ROOT/Package.swift" "$out/Package.swift" "$profile" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text = text.replace('"build/', '"Frameworks/').replace('build/FFmpegLGPL', 'Frameworks/FFmpegLGPL').replace('build/LibASS', 'Frameworks/LibASS')
default = '?? "core"'
assert default in text, 'the default profile is not where the export expects it'
text = text.replace(default, '?? "%s"' % sys.argv[3])
text = re.sub(r'\n        \.testTarget\(.*?\n        \),', '', text, flags=re.S)
assert 'testTarget' not in text, 'test target still in the exported manifest'
assert '"build/' not in text, 'a build/ path is left in the exported manifest'
first, rest = text.split("\n", 1)          # the tools-version comment must stay the first line
assert first.startswith("// swift-tools-version")
open(sys.argv[2], 'w').write(first + "\n// Exported by scripts/export-package.sh from the development manifest. Do not edit.\n" + rest)
PY
log "package exported ($profile by default): $out ($(find "$out" -type f | wc -l | tr -d ' ') files)"
