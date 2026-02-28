# User Guide

## What WadsReact Does

WadsReact lets you watch a `Show / Movie` and a `Reaction` at the same time, then keep them aligned using reaction offset controls.

## Supported Inputs

### Show / Movie

- Local files selected from `Choose Show/Movie`
- Common AVPlayer-compatible formats (for example MP4/MOV)
- MKV files are attempted through conversion/remux before playback

### Reaction

- Local files selected from `Choose Reaction`
- URL from `Choose Reaction from URL`
- YouTube links (embedded player)
- Vimeo page links (app attempts to resolve to playable stream URL)
- Direct media URLs (for example `.mp4`, `.m3u8`)

## Main Workflow

1. Select your show/movie.
2. Select reaction from file or URL.
3. Use `Play/Pause`, scrubber, and skip controls.
4. Adjust `Reaction Offset` so both videos line up.

## Reaction Offset Controls

- `Earlier`: reaction plays sooner
- `Later`: reaction plays later
- Step menu supports: `0.05`, `0.10`, `0.50`, `1`, `5`, `15` seconds
- Offset value is directly editable
- `Match Frames`: calculates offset from current paused frames
- `Reset Offset`: returns offset to `0`

Offset semantics:

- Positive offset = reaction delayed relative to show
- Negative offset = reaction advanced relative to show

## Transport

- Scrubber seeks timeline
- Skip backward/forward 10 seconds
- Central play/pause
- Time display for current and total duration

## Volume and Mute

- Independent volume sliders for show and reaction
- Independent mute buttons for each side

## Subtitles

- Subtitles are for `Show / Movie` only
- Choose subtitle track from `Subtitles (Main Video)` menu
- `None` disables subtitles

## Theatre Mode

Theatre mode minimizes controls and focuses on playback.

- Main video fills the window area (top aligned)
- Reaction appears as in-window PiP
- PiP can be dragged and resized
- On iOS, PiP is allowed partially off-screen
- PiP handles fade out automatically and reappear on interaction
- Main video vertical nudge buttons are shown bottom-left
- Exit button is shown bottom-right

Controls in theatre mode are native `VideoPlayer` controls for the main video.

## File Access on iOS/iPadOS

The app enables Files/Finder sharing support (`UIFileSharingEnabled` and opening in place).

## Notes

- YouTube playback quality, availability, and controls depend on embed restrictions.
- Some content owners disable embedded playback.
