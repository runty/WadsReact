# Troubleshooting

## Common Playback Errors

## “Unable to Open Video”

General causes:

- unsupported codec/container for AVPlayer
- remote URL is a web page, not a direct media URL
- source is geo-restricted or access-restricted

Action:

- try a known-good MP4 (H.264 + AAC)
- for URLs, prefer direct `.mp4` or `.m3u8`

## MKV Fails to Convert

Symptoms:

- repeated messages saying remux/export produced unplayable output
- AVFoundation errors like `AVFoundationErrorDomain -11800` with underlying OSStatus

Meaning:

- source streams are not becoming AVPlayer-compatible through current remux/export path

Action:

- use an external transcode to H.264/AAC MP4
- or wait for embedded full-transcode support in app

## YouTube Errors

Examples:

- video unavailable
- embedding disabled
- generic player error code

Action:

- open the same video on youtube.com to verify availability
- test another public video known to allow embeds

## Vimeo URL Not Loading

Action:

- use canonical Vimeo URL format (`vimeo.com/<id>`)
- if private/protected, ensure URL includes required access hash
- if it still fails, try direct stream URL when possible

## Sync Feels Off

Action:

- use `Match Frames` while both sides are paused on corresponding frames
- then use `Earlier/Later` with small step (`0.05` or `0.10`)
- avoid scrubbing excessively during active playback when one side is YouTube

## PiP Drag/Resize Issues in Theatre Mode

Action:

- tap PiP to reveal handles
- drag from body to move, corner handle to resize
- on iOS, partial off-screen placement is allowed but some visible area is retained

## File Sharing Not Visible on iPad in Finder

Checklist:

- reconnect cable
- trust computer on device
- ensure app build currently installed is the one with sharing keys
- restart Finder and device if needed

## Developer Diagnostics

For build verification:

```bash
xcodebuild -project reactwatch.xcodeproj -scheme reactwatch -destination 'generic/platform=macOS' build
xcodebuild -project reactwatch.xcodeproj -scheme reactwatch -destination 'generic/platform=iOS' build
```
