# Contributing

## Scope

Contributions should preserve WadsReact’s core mission:

- dual-video synchronized playback
- practical sync adjustment workflow
- stable theatre mode PiP interaction

## Coding Guidelines

- Keep platform-specific code minimal and isolated
- Prefer clear state transitions over hidden side effects
- Avoid regressing sync stability for local-local playback
- Keep UI controls responsive on iPad landscape and macOS

## Before Opening a PR

1. Build for macOS and iOS using `xcodebuild`.
2. Manually verify:
   - choose show and reaction
   - offset adjustment
   - subtitle selection
   - theatre mode PiP move/resize
   - URL imports (YouTube and Vimeo)
3. If touching MKV pipeline, include tested sample characteristics in PR notes.

## PR Notes Template

- What changed
- Why it changed
- Platforms tested
- Manual test matrix run
- Known limitations or follow-up items
