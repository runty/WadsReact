# WadsReact

WadsReact is a SwiftUI app for iOS, iPadOS, and macOS that plays two videos in sync:

- `Show / Movie` (main video)
- `Reaction` (local file, direct media URL, Vimeo-resolved URL, or YouTube embed)

The app provides reaction offset controls, per-video volume controls, subtitle selection for the main video, and a theatre mode with draggable/resizable in-window PiP.

## Documentation

- [Docs Index](docs/README.md)
- [User Guide](docs/USER_GUIDE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Sync Engine](docs/SYNC_ENGINE.md)
- [Media Compatibility](docs/MEDIA_COMPATIBILITY.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Developer Guide](docs/DEVELOPER_GUIDE.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Release Checklist](docs/RELEASE_CHECKLIST.md)
- [Local FFmpeg XCFramework Integration](docs/ffmpeg-local.md)

## Quick Start

1. Open `reactwatch.xcodeproj` in Xcode.
2. Select scheme `reactwatch`.
3. Run for a macOS target, iPad simulator/device, or iPhone simulator/device.

CLI build examples:

```bash
xcodebuild -project reactwatch.xcodeproj -scheme reactwatch -destination 'generic/platform=macOS' build
xcodebuild -project reactwatch.xcodeproj -scheme reactwatch -destination 'generic/platform=iOS' build
```

## Current Scope

- Primary use case: watch and align show + reaction content with manual and assisted sync tools.
- MKV support currently uses conversion/remux attempts before playback; some MKV files still cannot be converted to AVPlayer-compatible output.
- YouTube playback uses web embed behavior and is subject to YouTube embed restrictions.

## App Name

- Window/app display name: `WadsReact`

## Third-Party Components

- Embedded FFmpeg artifacts and license notice are included in:
  - `Vendor/FFmpegLocal`
  - `THIRD_PARTY_NOTICES/FFmpeg.txt`
