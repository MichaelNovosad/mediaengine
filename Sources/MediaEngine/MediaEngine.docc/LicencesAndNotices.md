# Licences, notices and replacing FFmpeg

## What you have to show

The engine uses FFmpeg under the LGPL 2.1 or later and a few small libraries under permissive licences. Show them in your app, for
example on a licences screen:

```swift
ForEach(MediaEngine.acknowledgements) { item in
    DisclosureGroup("\(item.name) \(item.version), \(item.license)") {
        if let notice = item.requiredNotice { Text(notice) }
        Text(item.licenseText)
    }
}
```

``MediaEngine/acknowledgements`` lists exactly the components inside the binary you linked (the AV1 decoder only in the extended
variant). FreeType's licence makes its credit line (``Acknowledgement/requiredNotice``) a condition of shipping.

## FFmpeg can be replaced

FFmpeg is linked dynamically as `FFmpegLGPL.framework`, so the people who receive your app can replace it with their own build.
`docs/REPLACING-FFMPEG.md` in the repository is the procedure and `scripts/test-framework-swap.sh` tests it. Every release comes with a
source pack (the exact upstream archives, the build scripts and `BUILD-INFO.txt` with the configure lines).

## Trademarks and patents

Spell it "FFmpeg"; do not use Dolby, DTS or Atmos marks as branding. The codecs of each profile and their licensing status are in
`docs/PATENT_PROFILES.md` (a draft for a lawyer): you are responsible for the patent licences of the profiles you enable.
