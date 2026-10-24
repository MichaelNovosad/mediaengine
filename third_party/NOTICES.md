# Third-party notices

This product uses libraries from the FFmpeg project under the GNU Lesser General Public License, version 2.1 or later.

| Component | Version | License | Source |
|---|---|---|---|
| FFmpeg (libavutil, libavcodec, libavformat, libswresample) | 9.0.2 | LGPL-2.1-or-later | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz (SHA-256 in `sources.lock`) |

- FFmpeg is built without `--enable-gpl` and `--enable-nonfree` and linked dynamically (`FFmpegLGPL.framework`). You may replace that framework with your own build of FFmpeg.
- We do not own FFmpeg. Its authors are listed at https://ffmpeg.org/developer.html and in the source archive (`CREDITS`).
- The configure line used for every released binary is in `BUILD-INFO.txt`, shipped next to the binaries together with the exact source archive and any patches (currently none).
- The full text of the license is in the source archive (`COPYING.LGPLv2.1`).

Additional components will be listed here when they ship (dav1d, libass, FreeType, HarfBuzz, FriBidi).
