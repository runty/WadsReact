# Media Compatibility

## Local File Playback

Playback ultimately depends on AVPlayer codec/container support.

### Generally Reliable

- MP4/MOV with H.264/H.265 video and AAC audio
- HLS `.m3u8` URLs (when accessible)

### MKV

MKV is not guaranteed to play directly. The app attempts conversion/remux paths first.

Current embedded remux path is conservative:

- Video codecs: H.264, HEVC
- Audio codecs: AAC, ALAC, MP3
- Stream selection: primary video + optional primary audio

If source codecs are incompatible with AVPlayer and remux/export attempts fail, playback will fail.

## URL Sources

### YouTube

- Uses embedded iframe player in WKWebView
- Subject to embed permissions and provider restrictions
- Some videos cannot be embedded (owner policy)

### Vimeo

- App resolves player page config to direct stream candidates
- Resolution can fail if Vimeo changes page format or blocks access

### Direct URL

- Expected to be direct media stream/file URL
- Hosted page URLs are not always playable by AVPlayer

## Subtitles

- Subtitle selection is available only for main video
- Only tracks exposed by AVFoundation are selectable

## Platform Notes

- iOS/iPadOS: Files/Finder sharing keys are enabled in `Info-iOS.plist`
- macOS: optional fallback to system `ffmpeg` if installed and discoverable
