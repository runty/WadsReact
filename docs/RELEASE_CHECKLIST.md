# Release Checklist

## Build and Signing

1. Confirm version/build values are updated in Xcode.
2. Build macOS target.
3. Build iOS target.
4. Archive each distribution target as needed.

## Functional Verification

1. Local show + local reaction playback works.
2. Offset controls (`Earlier/Later`, editable offset, step sizes) work.
3. `Match Frames` and `Reset Offset` work.
4. Subtitle menu works on main video.
5. Theatre mode:
   - main video top alignment
   - PiP drag/resize
   - PiP controls fade and reappear
   - exit button works
6. URL imports:
   - at least one YouTube URL
   - at least one Vimeo URL
   - at least one direct media URL

## MKV Smoke Test

1. Test at least one MKV that is known to convert successfully.
2. Test at least one MKV known to fail, verify diagnostics are readable.

## Packaging and Notices

1. Verify `THIRD_PARTY_NOTICES/FFmpeg.txt` is present.
2. Verify docs are up to date:
   - `README.md`
   - `docs/`
3. Confirm embedded FFmpeg artifacts are intentional for the release branch/tag.

## Post-Release

1. Tag release.
2. Publish release notes including known media compatibility limits.
