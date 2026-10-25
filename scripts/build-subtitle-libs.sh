#!/bin/bash
# Builds static FreeType, HarfBuzz, FriBidi and libass for one slice from the pinned sources.
# usage: scripts/build-subtitle-libs.sh <slice>
#   slices: macos ios ios-simulator xros xros-simulator   (all arm64)
# Everything goes to build/install/subs-<slice>; scripts/package-subtitle-xcframework.sh links it into LibASS.framework.
# Licences: libass ISC, FreeType under the FreeType License (FTL option), HarfBuzz MIT, FriBidi LGPL-2.1 (it stays in a
# dynamic framework, so it can be replaced). No GPL component is involved.
# Out-of-tree: nothing is built inside the downloaded source directories.
source "$(dirname "$0")/lib/common.sh"

slice="${1:?usage: build-subtitle-libs.sh <slice>}"
ft_v="$(lock_field freetype 2)"; hb_v="$(lock_field harfbuzz 2)"; fb_v="$(lock_field fribidi 2)"; as_v="$(lock_field libass 2)"
for d in freetype-$ft_v harfbuzz-$hb_v fribidi-$fb_v libass-$as_v; do
  [ -d "$BUILD/src/$d" ] || die "source $d missing; run scripts/fetch-sources.sh first"
done

tag="subs-$slice"
work="$BUILD/work/$tag"
prefix="$BUILD/install/$tag"
rm -rf "$work" "$prefix"; mkdir -p "$work" "$prefix"

sdk="$(slice_sdk "$slice")"; target="$(slice_target "$slice")"; sysroot="$(slice_sysroot "$slice")"
cc="$(xcrun --sdk "$sdk" --find clang)"; cxx="$(xcrun --sdk "$sdk" --find clang++)"
cflags="-target $target -isysroot $sysroot -O2 -g -fPIC"
cxxflags="$cflags"
ldflags="-target $target -isysroot $sysroot"
# `--host` makes autoconf cross-compile (it never runs what it builds); the triple only names the platform family.
host="aarch64-apple-darwin"
build_triple="$("$BUILD/src/freetype-$ft_v/builds/unix/config.guess")"

run() { # <name> <logfile> <command...>
  local name="$1" logfile="$2"; shift 2
  "$@" > "$logfile" 2>&1 || { tail -30 "$logfile"; die "$name failed for $tag (see $logfile)"; }
}

# 1. FreeType: no optional libraries (no zlib, bzip2, png, brotli, harfbuzz): fonts come as plain TrueType/OpenType files.
log "freetype $ft_v for $tag"
mkdir -p "$work/freetype"; cd "$work/freetype"
run "freetype configure" configure.log "$BUILD/src/freetype-$ft_v/configure" --prefix="$prefix" --host="$host" --build="$build_triple" \
  --enable-static --disable-shared --with-pic --with-zlib=no --with-bzip2=no --with-png=no --with-brotli=no --with-harfbuzz=no \
  CC="$cc" CFLAGS="$cflags" LDFLAGS="$ldflags"
run "freetype make" make.log make -j"$(jobs_count)"
run "freetype install" install.log make install

# 2. HarfBuzz: the built-in shaper and Unicode data only (libass brings its own font glue).
log "harfbuzz $hb_v for $tag"
cmake_system="Darwin"
run "harfbuzz configure" "$work/harfbuzz-configure.log" cmake -S "$BUILD/src/harfbuzz-$hb_v" -B "$work/harfbuzz" -G Ninja \
  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME="$cmake_system" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="$sysroot" \
  -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$cxx" \
  -DCMAKE_C_FLAGS="$cflags" -DCMAKE_CXX_FLAGS="$cxxflags" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
  -DHB_HAVE_FREETYPE=OFF -DHB_HAVE_CORETEXT=OFF -DHB_HAVE_GLIB=OFF -DHB_HAVE_ICU=OFF -DHB_HAVE_GRAPHITE2=OFF -DHB_HAVE_CAIRO=OFF \
  -DHB_BUILD_UTILS=OFF -DHB_BUILD_SUBSET=OFF -DHB_BUILD_RASTER=OFF -DHB_BUILD_VECTOR=OFF -DHB_BUILD_GPU=OFF
run "harfbuzz build" "$work/harfbuzz-build.log" cmake --build "$work/harfbuzz" -j"$(jobs_count)"
run "harfbuzz install" "$work/harfbuzz-install.log" cmake --install "$work/harfbuzz"

# 3. FriBidi: only the library (the command-line tools and tests are not built).
log "fribidi $fb_v for $tag"
mkdir -p "$work/fribidi"; cd "$work/fribidi"
run "fribidi configure" configure.log "$BUILD/src/fribidi-$fb_v/configure" --prefix="$prefix" --host="$host" --build="$build_triple" \
  --enable-static --disable-shared --with-pic --disable-docs --disable-debug \
  CC="$cc" CFLAGS="$cflags" LDFLAGS="$ldflags"
run "fribidi make" make.log make -j"$(jobs_count)" -C gen.tab
run "fribidi make lib" make-lib.log make -j"$(jobs_count)" -C lib
run "fribidi install" install.log make -C lib install

# 4. libass: CoreText font provider, no Fontconfig, no assembly (it would need nasm), no libunibreak.
log "libass $as_v for $tag"
mkdir -p "$work/libass"; cd "$work/libass"
run "libass configure" configure.log "$BUILD/src/libass-$as_v/configure" --prefix="$prefix" --host="$host" --build="$build_triple" \
  --enable-static --disable-shared --with-pic --disable-fontconfig --enable-coretext --disable-libunibreak --disable-asm \
  --disable-require-system-font-provider --disable-test --disable-compare --disable-profile --disable-fuzz \
  CC="$cc" CFLAGS="$cflags" LDFLAGS="$ldflags" \
  FREETYPE_CFLAGS="-I$prefix/include/freetype2" FREETYPE_LIBS="-L$prefix/lib -lfreetype" \
  FRIBIDI_CFLAGS="-I$prefix/include/fribidi" FRIBIDI_LIBS="-L$prefix/lib -lfribidi" \
  HARFBUZZ_CFLAGS="-I$prefix/include/harfbuzz" HARFBUZZ_LIBS="-L$prefix/lib -lharfbuzz -lc++"
run "libass make" make.log make -j"$(jobs_count)"
run "libass install" install.log make install
grep -q 'define CONFIG_CORETEXT 1' config.h || die "libass was configured without the CoreText font provider ($work/libass/config.h)"

# Notices travel with the binaries.
mkdir -p "$prefix/licenses"
cp "$BUILD/src/libass-$as_v/COPYING" "$prefix/licenses/libass-ISC.txt"
cp "$BUILD/src/freetype-$ft_v/docs/FTL.TXT" "$prefix/licenses/freetype-FTL.txt"
cp "$BUILD/src/harfbuzz-$hb_v/COPYING" "$prefix/licenses/harfbuzz-MIT.txt"
cp "$BUILD/src/fribidi-$fb_v/COPYING" "$prefix/licenses/fribidi-LGPL-2.1.txt"
log "built $tag → $prefix"
