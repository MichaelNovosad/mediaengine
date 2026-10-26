# Replacing the FFmpeg framework (LGPL, LIC-2)

MediaEngine uses FFmpeg under the **GNU Lesser General Public License, version 2.1 or later**. FFmpeg is linked **dynamically**:
all of it lives in `FFmpegLGPL.framework`, which is embedded in your app next to your own code. The LGPL lets you, and the
people who receive an app built with this package, replace that framework with a build of FFmpeg of their own. This page is the
procedure; `scripts/test-framework-swap.sh` runs it on every release candidate (a client is built against one framework, the
framework next to it is replaced by another build, and the same executable is run again without relinking).

The same holds for `LibASS.framework`, which contains libass, FreeType, HarfBuzz and FriBidi (FriBidi is LGPL): replace it the
same way, with a build that exports the same `ass_*` functions.

## What you need

- The source pack of the release (`MediaEngine-sources-*.tar.xz`): the exact upstream archives with their signatures, the build
  scripts, the codec profiles (`profiles/*.json`, which decide the FFmpeg `configure` flags), `BUILD-INFO.txt` with the
  configure line of every binary, and the patches we apply (there are none). Written offer: we send the same material, free of
  charge, to anyone who received the binary.
- Xcode 27, `meson`, `ninja`, `cmake`, `gpg` (see `CLAUDE.md`), and a Mac.

## 1. Rebuild FFmpeg (your own configuration or your own FFmpeg source)

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
scripts/fetch-sources.sh                          # downloads the pinned archives and verifies SHA-256 and signatures
# (offline: put the archives from the source pack into build/downloads/<name>-<version>/ first)
scripts/build-ffmpeg.sh macos core                # one slice; repeat for ios ios-simulator xros xros-simulator
scripts/package-xcframework.sh core               # build/FFmpegLGPL.xcframework (dynamic framework, install name @rpath/FFmpegLGPL.framework/...)
```

To change what is compiled in, edit `profiles/core.json` (or add your own profile file) before building. To use another FFmpeg
version, change the pin in `third_party/sources.lock` (same major version of the `libav*` libraries: the framework must keep the
ABI the engine was compiled against). The extended variant additionally needs `scripts/build-dav1d.sh <slice>` first and is
packaged with `scripts/package-xcframework.sh core+extended`.

## 2. Put the new framework into an app that is already built

```bash
APP=/path/to/YourApp.app
rm -rf "$APP/Contents/Frameworks/FFmpegLGPL.framework"                  # iOS and visionOS: "$APP/Frameworks/..."
cp -R build/frameworks/macos/FFmpegLGPL.framework "$APP/Contents/Frameworks/"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/FFmpegLGPL.framework"   # or your own identity
codesign --force --sign - --timestamp=none "$APP"                       # re-sign the app (signatures cover the embedded framework)
```

Requirements for the replacement:

- **Install name** `@rpath/FFmpegLGPL.framework/Versions/A/FFmpegLGPL` on macOS, `@rpath/FFmpegLGPL.framework/FFmpegLGPL` on the
  other platforms (what `scripts/package-xcframework.sh` produces).
- **Exported symbols**: at least every function listed in `REQUIRED-FFMPEG-SYMBOLS.txt` (the `av*` and `swr*` functions the
  engine calls; the test checks both shipped builds against it). Exporting all of FFmpeg's public API is fine.
- **ABI**: the same major versions of libavutil, libavcodec, libavformat and libswresample as the pinned FFmpeg (the engine's
  structures are read through FFmpeg's headers, which are inside the framework).
- Features follow the replacement: the engine asks the framework which decoders it has (`MediaEngine.availableProfiles`), so a
  build with more decoders makes more files playable and a build with fewer makes the plan report them as needing a module.
  You are responsible for the patent licences of whatever you compile in.

## 3. Check

Run your app, or the smallest client: `Samples/SwapProbe` prints the FFmpeg version, the profiles it found and what it would do
with a file. `scripts/test-framework-swap.sh` does the whole round trip.
