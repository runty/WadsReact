# Sync Engine

## Core Model

The sync model aligns reaction time to primary time using:

`reaction_target = max(0, primary_time - reaction_offset_seconds)`

Where:

- `reaction_offset_seconds > 0` means reaction is delayed
- `reaction_offset_seconds < 0` means reaction is advanced

## Playback Entry Points

- `play()` starts synchronized playback when both videos exist
- `seek(to:)` seeks both sides when both videos exist
- `realignReactionToPrimary()` explicitly snaps reaction to offset target

## Drift Management

Drift correction runs while both are playing.

### Non-YouTube Reaction

- If drift is large: hard seek reaction
- If drift is medium: adjust reaction playback rate toward target
- If drift is tiny: normalize rate back to `1.0`

### YouTube Reaction

- Coarse seek-based correction only
- Minimum interval between corrections to reduce stutter

## Offset Auto-Adjustment During Independent Pause

If one side is paused and the other keeps playing:

- Offset is continuously updated to reflect actual frame delta
- When both end up paused, offset is finalized from current frame positions

This enables the “pause one side, continue the other, pause, then resume together” workflow.

## Match Frames Action

`Match Frames` sets offset from current frame times directly:

`reaction_offset = primary_seconds - reaction_seconds`

## Threshold Constants

The current implementation uses fixed thresholds in `DualPlayerViewModel` for:

- hard resync threshold
- rate correction threshold
- max rate adjustment
- YouTube correction interval and threshold

Tune those constants if your media characteristics change.
