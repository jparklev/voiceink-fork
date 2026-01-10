# VoiceInk Development Notes

## Upstream Sync

This is a development fork of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk). Before starting significant work, check for upstream changes:

```bash
git fetch upstream
git log main..upstream/main --oneline
```

Review changes with the user before merging. Key areas to watch:
- Audio engine / recording stability fixes
- Hotkey timing improvements
- Power Mode enhancements
- API key / Keychain storage changes

## Build & Run

```bash
# Build
xcodebuild -scheme VoiceInk -configuration Debug build

# Launch latest debug build
open ~/Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/Debug/VoiceInk.app

# Kill and relaunch
pkill -9 VoiceInk && sleep 0.5 && open ~/Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/Debug/VoiceInk.app
```

## Validation

Run the validation script to test recording E2E:
```bash
uv run validate_recording.py --skip-launch
```

## Architecture Notes

### Audio Engine (Output-First Warmup)

The recording system uses a pre-warmed `AVAudioEngine` for fast startup:

1. **App launch**: Engine starts with output-only graph (no mic indicator)
2. **Recording start**: Input tap attached, mic indicator appears
3. **Recording stop**: Engine destroyed and recreated output-only (clears mic indicator)

Key insight: Once `engine.inputNode` is accessed, that engine instance is "tainted" - the mic indicator persists even after removing the tap. Must destroy and recreate the engine to clear it.

Key files:
- `VoiceInk/AudioEngineRecorder.swift` - Core engine management
- `VoiceInk/Recorder.swift` - High-level recording interface
