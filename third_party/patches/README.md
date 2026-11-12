# Patches

Our changes to the third-party sources, as unified diffs named `<component>-<number>-<what>.diff` (the component as in
`../sources.lock`). `scripts/fetch-sources.sh` applies them in file-name order with `patch -p1` when it extracts an archive,
and extracts the archive again when the set of patches changes. They are counted in `BUILD-INFO.txt` and shipped in the
source pack. Every diff must be against exactly the archive named in `../sources.lock` (the source pack check fails on a
count that does not match).

- `ffmpeg-0001-dts-core-only.diff` (owner's decision of 2026-11-12, `docs/RESEARCH.md` section 3.2 point 6): the `dca`
  decoder decodes only the original DTS core; the DTS-HD lossless (XLL) and DTS Express (LBR) decoders are not compiled,
  and the parsers of the extension sub-stream and of the core's own extensions are removed. The header of the diff lists
  the details.
