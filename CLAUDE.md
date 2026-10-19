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

### Audio Capture

`CoreAudioRecorder` drives an AUHAL input unit. Each recording creates a new unit and disposes it on stop, which clears the mic indicator. The render callback mixes to mono, then `MonoResampler` (an `AudioConverter`) filters and resamples to 16 kHz Int16. The output goes to the WAV file and to `onAudioChunk` for streaming.

Key files:
- `VoiceInk/CoreAudioRecorder.swift` - AUHAL unit, render callback, file writing
- `VoiceInk/MonoResampler.swift` - sample-rate conversion
- `VoiceInk/Recorder.swift` - High-level recording interface
- `VoiceInk/Transcription/Engine/AudioFileProcessor.swift` - `AudioProcessor.samples16kMono` decodes any audio file for local models
