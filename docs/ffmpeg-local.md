# Local FFmpeg XCFramework Integration

This repository includes a local FFmpeg build path packaged as XCFrameworks and consumed through a local Swift package.

## Components

- Build script: `scripts/build_ffmpeg_apple.sh`
- Local package: `Vendor/FFmpegLocal/Package.swift`
- Artifacts directory: `Vendor/FFmpegLocal/Artifacts/`
- Runtime bridge:
  - `reactwatch/FFmpegRemuxer.swift`
  - `reactwatch/DualPlayerViewModel.swift`

## Build Artifacts

From repository root:

```bash
scripts/build_ffmpeg_apple.sh
```

Generated artifacts:

- `Vendor/FFmpegLocal/Artifacts/Libavcodec.xcframework`
- `Vendor/FFmpegLocal/Artifacts/Libavformat.xcframework`
- `Vendor/FFmpegLocal/Artifacts/Libavutil.xcframework`

Target slices built by script:

- iOS device: `arm64`
- iOS simulator: `arm64` + `x86_64`
- macOS: `arm64` + `x86_64`

## Xcode Wiring

This project is already wired to the local package.

`reactwatch` target links:

- `Libavutil`
- `Libavcodec`
- `Libavformat`

If package links are removed, re-add local package `Vendor/FFmpegLocal` and attach those products back to target `reactwatch`.

## Build Verification

```bash
xcodebuild -project reactwatch.xcodeproj -scheme reactwatch -destination 'generic/platform=iOS' build
xcodebuild -project reactwatch.xcodeproj -scheme reactwatch -destination 'generic/platform=macOS' build
```

## Runtime Behavior (Current)

When linked, embedded FFmpeg is used as the first MKV preparation step.

Current behavior is remux-oriented and conservative:

- picks primary compatible video stream
- optionally picks primary compatible audio stream
- writes MP4 and normalizes timestamps for mux compatibility
- retries video-only when needed
- includes read/write interrupt watchdog to avoid long stalls

If embedded remux output is still unplayable, the app falls back to additional AVFoundation conversion steps and optional macOS system-`ffmpeg` fallback.

## Limitations

- Embedded path currently does not implement full decode/re-encode transcoding.
- Some MKVs remain unplayable even after remux/export fallback attempts.

## Licensing

FFmpeg license notice is included at:

- `THIRD_PARTY_NOTICES/FFmpeg.txt`
