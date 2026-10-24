#!/bin/bash
# Builds static FFmpeg libraries for one slice from the pinned source.
# usage: scripts/build-ffmpeg.sh <slice> [profile...]     (default profile: core)
#   slices: macos ios ios-simulator xros xros-simulator   (all arm64)
# Out-of-tree: nothing is built inside the downloaded source directory.
source "$(dirname "$0")/lib/common.sh"

slice="${1:?usage: build-ffmpeg.sh <slice> [profile...]}"; shift || true
if [ "$#" -eq 0 ]; then set -- core; fi

version="$(lock_field ffmpeg 2)"
src="$BUILD/src/ffmpeg-$version"
[ -d "$src" ] || die "source missing; run scripts/fetch-sources.sh first"

tag="$slice-$(echo "$*" | tr ' ' '+')"
work="$BUILD/work/ffmpeg/$tag"
prefix="$BUILD/install/$tag"
rm -rf "$work" "$prefix"; mkdir -p "$work" "$prefix"

sdk="$(slice_sdk "$slice")"; target="$(slice_target "$slice")"; sysroot="$(slice_sysroot "$slice")"
cc="$(xcrun --sdk "$sdk" --find clang)"

flags_file="$work/profile-flags.txt"
python3 -I "$ROOT/scripts/gen-config.py" flags "$@" > "$flags_file"
python3 -I "$ROOT/scripts/gen-config.py" report "$@" > "$prefix/LICENSE-REPORT.md"

cross=""
if [ "$slice" != "macos" ]; then cross="--enable-cross-compile"; fi

log "configure ffmpeg $version for $tag"
cd "$work"
# shellcheck disable=SC2046
"$src/configure" \
  --prefix="$prefix" $cross \
  --target-os=darwin --arch=arm64 \
  --cc="$cc" \
  --host-cc="$(xcrun --sdk macosx --find clang)" \
  --host-cflags="-isysroot $(xcrun --sdk macosx --show-sdk-path)" \
  --host-ldflags="-isysroot $(xcrun --sdk macosx --show-sdk-path)" \
  --extra-cflags="-target $target -isysroot $sysroot -O2 -g" \
  --extra-ldflags="-target $target -isysroot $sysroot" \
  --enable-static --disable-shared --enable-pic \
  --disable-doc --disable-autodetect --disable-network --disable-debug \
  --disable-gpl --disable-nonfree \
  $(tr '\n' ' ' < "$flags_file") \
  > configure.log 2>&1 || { tail -30 configure.log; die "configure failed for $tag (see $work/configure.log)"; }

log "make $tag"
make -j"$(jobs_count)" > make.log 2>&1 || { tail -30 make.log; die "make failed for $tag (see $work/make.log)"; }
make install > install.log 2>&1 || die "make install failed for $tag"
cp config.h "$prefix/config.h" 2>/dev/null || true
log "built $tag → $prefix"
