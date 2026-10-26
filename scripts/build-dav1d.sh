#!/bin/bash
# Builds the static dav1d AV1 decoder (BSD-2-Clause) for one slice from the pinned source; FFmpeg's `libdav1d` wrapper
# (profile extended) links it into the extended variant. Out of tree, with a meson cross file written here.
# usage: scripts/build-dav1d.sh <slice>      slices: macos ios ios-simulator xros xros-simulator   (all arm64)
source "$(dirname "$0")/lib/common.sh"

slice="${1:?usage: build-dav1d.sh <slice>}"
version="$(lock_field dav1d 2)"
src="$BUILD/src/dav1d-$version"
[ -d "$src" ] || die "source missing; run scripts/fetch-sources.sh first"
tag="dav1d-$slice"
work="$BUILD/work/$tag"; prefix="$BUILD/install/$tag"
rm -rf "$work" "$prefix"; mkdir -p "$work" "$prefix"

sdk="$(slice_sdk "$slice")"; target="$(slice_target "$slice")"; sysroot="$(slice_sysroot "$slice")"
cc="$(xcrun --sdk "$sdk" --find clang)"; ar="$(xcrun --sdk "$sdk" --find ar)"; strip="$(xcrun --sdk "$sdk" --find strip)"
runnable=false; [ "$slice" = "macos" ] && runnable=true
cat > "$work/cross.ini" <<INI
[binaries]
c = '$cc'
ar = '$ar'
strip = '$strip'

[built-in options]
c_args = ['-target', '$target', '-isysroot', '$sysroot', '-O2', '-fPIC']
c_link_args = ['-target', '$target', '-isysroot', '$sysroot']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = $([ "$runnable" = true ] && echo false || echo true)
INI

log "dav1d $version for $tag"
meson setup "$work/build" "$src" --cross-file "$work/cross.ini" --prefix "$prefix" --libdir lib --buildtype release \
  --default-library static -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false \
  > "$work/setup.log" 2>&1 || { tail -30 "$work/setup.log"; die "dav1d setup failed for $tag"; }
{ echo "meson setup <build> <dav1d-$version source> --cross-file <below> --buildtype release --default-library static -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false"
  echo "meson $(meson --version), ninja $(ninja --version), clang $("$cc" --version | head -1)"
  echo "cross file:"; sed 's/^/  /' "$work/cross.ini"; } > "$prefix/BUILD-CONFIG.txt"
ninja -C "$work/build" > "$work/build.log" 2>&1 || { tail -30 "$work/build.log"; die "dav1d build failed for $tag"; }
ninja -C "$work/build" install > "$work/install.log" 2>&1 || die "dav1d install failed for $tag"
[ -f "$prefix/lib/libdav1d.a" ] || die "libdav1d.a missing"
mkdir -p "$prefix/licenses"; cp "$src/COPYING" "$prefix/licenses/dav1d-BSD-2-Clause.txt"
log "built $tag → $prefix"
