#!/usr/bin/env python3
"""
VoiceInk Recording Validation Script

Automated E2E testing for the recording feature:
1. Launches VoiceInk fresh
2. Attaches to log stream
3. Simulates hotkey to start recording
4. Waits, then stops recording
5. Validates: logs, WAV file creation, audio format, database entry

Usage:
    uv run validate_recording.py [--skip-launch] [--record-duration=5]
"""

import subprocess
import time
import os
import sys
import threading
import glob
import atexit
import argparse
from pathlib import Path
from collections import deque

# =============================================================================
# Configuration
# =============================================================================

BUNDLE_ID = "com.prakashjoshipax.voiceink"
LOG_PREDICATE = f'subsystem == "{BUNDLE_ID}"'

APP_SUPPORT_DIR = Path.home() / "Library/Application Support/com.prakashjoshipax.VoiceInk"
RECORDINGS_DIR = APP_SUPPORT_DIR / "Recordings"
DATABASE_PATH = APP_SUPPORT_DIR / "default.store"

# Hotkey configuration
# Keycodes: Right Command = 54 (0x36), Right Option = 61 (0x3D)
# The script will try to auto-detect from preferences
HOTKEY_KEYCODE = 61  # Right Option (commonly used)
HOTKEY_NAME = "Right Option"

# Map hotkey setting names to keycodes
HOTKEY_MAP = {
    "rightOption": (61, "Right Option"),
    "leftOption": (58, "Left Option"),
    "rightCommand": (54, "Right Command"),
    "leftCommand": (55, "Left Command"),
    "leftControl": (59, "Left Control"),
    "rightControl": (62, "Right Control"),
    "rightShift": (60, "Right Shift"),
    "fn": (63, "Fn"),
}


def detect_hotkey_from_preferences():
    """Try to detect the configured hotkey from VoiceInk preferences."""
    global HOTKEY_KEYCODE, HOTKEY_NAME

    # Try both production and debug bundle IDs
    bundle_ids = [
        "com.prakashjoshipax.VoiceInk",
        "com.joshlevine.VoiceInk.local",
    ]

    for bundle_id in bundle_ids:
        result = subprocess.run(
            ["defaults", "read", bundle_id, "selectedHotkey1"],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            hotkey_name = result.stdout.strip()
            if hotkey_name in HOTKEY_MAP:
                HOTKEY_KEYCODE, HOTKEY_NAME = HOTKEY_MAP[hotkey_name]
                print(f"   Auto-detected hotkey: {HOTKEY_NAME} (keycode {HOTKEY_KEYCODE})")
                return True

    print(f"   Using default hotkey: {HOTKEY_NAME} (keycode {HOTKEY_KEYCODE})")
    return False


def find_app_path():
    """Find the most recently built VoiceInk.app in DerivedData."""
    patterns = [
        # Debug builds
        str(Path.home() / "Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/Debug/VoiceInk.app"),
        # Release builds
        str(Path.home() / "Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/Release/VoiceInk.app"),
        # Installed app
        "/Applications/VoiceInk.app",
    ]

    for pattern in patterns:
        matches = glob.glob(pattern)
        if matches:
            # Return the most recently modified
            return max(matches, key=os.path.getmtime)

    return None


# =============================================================================
# Log Streaming
# =============================================================================

class LogCapture:
    """Captures macOS unified logs in a background thread."""

    def __init__(self, predicate: str, max_lines: int = 10000):
        self.predicate = predicate
        self.logs = deque(maxlen=max_lines)
        self.stop_event = threading.Event()
        self.thread = None
        self.proc = None

    def start(self):
        self.thread = threading.Thread(target=self._stream_logs, daemon=True)
        self.thread.start()
        time.sleep(0.5)  # Give it time to attach

    def stop(self):
        self.stop_event.set()
        if self.proc:
            self.proc.terminate()
        if self.thread:
            self.thread.join(timeout=2)

    def _stream_logs(self):
        self.proc = subprocess.Popen(
            ["log", "stream", "--predicate", self.predicate, "--level", "debug"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        while not self.stop_event.is_set():
            line = self.proc.stdout.readline()
            if line:
                self.logs.append(line.strip())
            elif self.proc.poll() is not None:
                break

    def contains(self, text: str) -> bool:
        # Take a snapshot to avoid deque mutation during iteration
        logs_snapshot = list(self.logs)
        return any(text in log for log in logs_snapshot)

    def get_all(self) -> str:
        return "\n".join(list(self.logs))

    def get_recent(self, n: int = 20) -> str:
        logs_snapshot = list(self.logs)
        return "\n".join(logs_snapshot[-n:])


# =============================================================================
# Hotkey Simulation
# =============================================================================

def trigger_hotkey_applescript():
    """Simulate the VoiceInk recording hotkey via AppleScript (may not work for modifier keys)."""
    print(f"   Simulating {HOTKEY_NAME} (keycode {HOTKEY_KEYCODE}) via AppleScript...")
    script = f'tell application "System Events" to key code {HOTKEY_KEYCODE}'
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True
    )
    if result.returncode != 0:
        print(f"   ⚠️  AppleScript error: {result.stderr}")
        return False
    return True


def trigger_hotkey_cgevent():
    """
    Simulate modifier key press using CGEvent.
    This properly sets the modifier flags that VoiceInk monitors.
    """
    print(f"   Simulating {HOTKEY_NAME} (keycode {HOTKEY_KEYCODE}) via CGEvent...")

    # Swift/ObjC snippet to simulate modifier key press
    # Using a small Swift script inline
    swift_code = f'''
import Cocoa
import CoreGraphics

// Keycode to CGEventFlags mapping
let keycode: CGKeyCode = {HOTKEY_KEYCODE}
var flags: CGEventFlags = []

// Map keycode to modifier flag
switch keycode {{
case 54, 55: flags = .maskCommand      // Right/Left Command
case 58, 61: flags = .maskAlternate    // Left/Right Option
case 59, 62: flags = .maskControl      // Left/Right Control
case 56, 60: flags = .maskShift        // Left/Right Shift
case 63:     flags = .maskSecondaryFn  // Fn
default: break
}}

// Key down with modifier flags
if let eventDown = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true) {{
    eventDown.flags = flags
    eventDown.post(tap: .cghidEventTap)
}}

// Small delay
usleep(50000)  // 50ms

// Key up (clear flags)
if let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) {{
    eventUp.flags = []
    eventUp.post(tap: .cghidEventTap)
}}
'''

    result = subprocess.run(
        ["swift", "-e", swift_code],
        capture_output=True,
        text=True,
        timeout=10
    )

    if result.returncode != 0:
        print(f"   ⚠️  CGEvent simulation error: {result.stderr}")
        return False
    return True


def trigger_hotkey_notification():
    """
    Directly post the toggleMiniRecorder notification via Swift.
    This bypasses hotkey simulation entirely.
    """
    print(f"   Posting .toggleMiniRecorder notification directly...")

    swift_code = '''
import Foundation
import Cocoa

// Get the running VoiceInk app
let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.prakashjoshipax.VoiceInk")
guard let app = runningApps.first else {
    print("VoiceInk not running")
    exit(1)
}

// Unfortunately we can't post to another process's NotificationCenter directly
// But we can use distributed notifications
DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name("com.prakashjoshipax.VoiceInk.toggleMiniRecorder"),
    object: nil,
    userInfo: nil,
    deliverImmediately: true
)
print("Notification posted")
'''

    result = subprocess.run(
        ["swift", "-e", swift_code],
        capture_output=True,
        text=True,
        timeout=10
    )

    if result.returncode != 0:
        print(f"   ⚠️  Notification error: {result.stderr}")
        return False
    return True


def trigger_hotkey():
    """
    Simulate the VoiceInk recording hotkey.
    Tries multiple methods in order of likelihood to work.
    """
    # Method 0: Distributed notification (debug builds)
    if trigger_hotkey_notification():
        return True

    # Method 1: CGEvent (best for modifier keys)
    if trigger_hotkey_cgevent():
        return True

    # Method 2: AppleScript (fallback)
    print("   Falling back to AppleScript...")
    return trigger_hotkey_applescript()


# =============================================================================
# File System Validation
# =============================================================================

def get_recordings() -> list[Path]:
    """Get all WAV recordings sorted by modification time (newest first)."""
    if not RECORDINGS_DIR.exists():
        return []
    wavs = list(RECORDINGS_DIR.glob("*.wav"))
    return sorted(wavs, key=lambda p: p.stat().st_mtime, reverse=True)


def get_newest_recording() -> Path | None:
    """Get the most recent recording file."""
    recordings = get_recordings()
    return recordings[0] if recordings else None


def validate_audio_format(wav_path: Path) -> dict:
    """Validate WAV file format using afinfo."""
    result = subprocess.run(
        ["afinfo", str(wav_path)],
        capture_output=True,
        text=True
    )

    info = {
        "valid": False,
        "format": None,
        "duration": None,
        "sample_rate": None,
        "channels": None,
        "bit_depth": None,
        "raw": result.stdout
    }

    if result.returncode != 0:
        info["error"] = result.stderr
        return info

    output = result.stdout

    # Parse "Data format: 1 ch, 16000 Hz, Int16"
    if "Data format:" in output:
        for line in output.split("\n"):
            if "Data format:" in line:
                info["format"] = line.split("Data format:")[1].strip()
                # Check expected format
                if "1 ch" in line and "16000 Hz" in line and "Int16" in line:
                    info["valid"] = True
                    info["channels"] = 1
                    info["sample_rate"] = 16000
                    info["bit_depth"] = 16

    # Parse duration
    if "estimated duration:" in output:
        for line in output.split("\n"):
            if "estimated duration:" in line:
                try:
                    duration_str = line.split("estimated duration:")[1].strip()
                    info["duration"] = float(duration_str.replace(" sec", ""))
                except:
                    pass

    return info


# =============================================================================
# Database Validation
# =============================================================================

def get_latest_transcription() -> dict | None:
    """Query the SwiftData database for the most recent transcription."""
    if not DATABASE_PATH.exists():
        return None

    query = """
    SELECT
        ZTEXT,
        ZTRANSCRIPTIONSTATUS,
        ZDURATION,
        ZTRANSCRIPTIONDURATION,
        datetime(ZTIMESTAMP + 978307200, 'unixepoch', 'localtime') as timestamp
    FROM ZTRANSCRIPTION
    ORDER BY ZTIMESTAMP DESC
    LIMIT 1;
    """

    result = subprocess.run(
        ["sqlite3", "-separator", "|", str(DATABASE_PATH), query],
        capture_output=True,
        text=True
    )

    if result.returncode != 0 or not result.stdout.strip():
        return None

    parts = result.stdout.strip().split("|")
    if len(parts) >= 5:
        return {
            "text": parts[0][:100] + "..." if len(parts[0]) > 100 else parts[0],
            "status": parts[1],
            "audio_duration": float(parts[2]) if parts[2] else None,
            "transcription_duration": float(parts[3]) if parts[3] else None,
            "timestamp": parts[4],
        }
    return None


# =============================================================================
# Main Validation Flow
# =============================================================================

def cleanup():
    """Cleanup function registered with atexit."""
    # Don't kill the app on exit - let user inspect if needed
    pass


def main():
    global HOTKEY_KEYCODE, HOTKEY_NAME

    parser = argparse.ArgumentParser(description="VoiceInk Recording Validation")
    parser.add_argument("--skip-launch", action="store_true", help="Don't launch app, assume it's running")
    parser.add_argument("--record-duration", type=int, default=3, help="Recording duration in seconds")
    parser.add_argument("--hotkey", type=int, default=None, help="Hotkey keycode to use (auto-detects if not specified)")
    args = parser.parse_args()

    atexit.register(cleanup)

    print("=" * 60)
    print("VoiceInk Recording Validation")
    print("=" * 60)
    print()

    # Detect or set hotkey
    print("[0/7] Configuring hotkey...")
    if args.hotkey is not None:
        HOTKEY_KEYCODE = args.hotkey
        HOTKEY_NAME = f"Custom (keycode {args.hotkey})"
        print(f"   Using specified hotkey: {HOTKEY_NAME}")
    else:
        detect_hotkey_from_preferences()
    print()

    results = {
        "app_launch": None,
        "recording_started": None,
        "recording_latency_ms": None,
        "wav_created": None,
        "audio_format_valid": None,
        "audio_duration": None,
        "transcription_started": None,
        "transcription_completed": None,
        "errors": []
    }

    # -------------------------------------------------------------------------
    # Step 1: Launch App
    # -------------------------------------------------------------------------
    if not args.skip_launch:
        print("[1/7] Launching VoiceInk...")

        # Kill existing instances
        subprocess.run(["pkill", "-x", "VoiceInk"], capture_output=True)
        time.sleep(1)

        app_path = find_app_path()
        if not app_path:
            print("   ❌ Could not find VoiceInk.app")
            print("   Searched in DerivedData and /Applications")
            results["app_launch"] = False
            results["errors"].append("App not found")
            return results

        print(f"   Found: {app_path}")
        subprocess.run(["open", app_path])

        print("   Waiting 5s for app initialization...")
        time.sleep(5)

        # Verify app is running
        result = subprocess.run(["pgrep", "-x", "VoiceInk"], capture_output=True)
        if result.returncode != 0:
            print("   ❌ App failed to start")
            results["app_launch"] = False
            results["errors"].append("App failed to start")
            return results

        print("   ✅ App launched successfully")
        results["app_launch"] = True
    else:
        print("[1/7] Skipping launch (--skip-launch)")
        result = subprocess.run(["pgrep", "-x", "VoiceInk"], capture_output=True)
        if result.returncode != 0:
            print("   ❌ VoiceInk is not running")
            results["errors"].append("App not running")
            return results
        print("   ✅ VoiceInk is running")
        results["app_launch"] = True

    # -------------------------------------------------------------------------
    # Step 2: Start Log Capture
    # -------------------------------------------------------------------------
    print("\n[2/7] Starting log capture...")
    log_capture = LogCapture(LOG_PREDICATE)
    log_capture.start()
    print(f"   ✅ Attached to log stream (predicate: {LOG_PREDICATE})")
    time.sleep(1)

    # -------------------------------------------------------------------------
    # Step 3: Snapshot Recordings Before
    # -------------------------------------------------------------------------
    print("\n[3/7] Snapshotting recordings directory...")
    before_recording = get_newest_recording()
    before_count = len(get_recordings())
    print(f"   Current recording count: {before_count}")
    if before_recording:
        print(f"   Latest: {before_recording.name}")

    # -------------------------------------------------------------------------
    # Step 4: Start Recording
    # -------------------------------------------------------------------------
    print("\n[4/7] Starting recording...")
    start_time = time.time()

    if not trigger_hotkey():
        results["errors"].append("Hotkey simulation failed")

    # Wait for recording to start (watch logs)
    # Detect various recording startup messages
    print("   Watching for recording startup...")
    recording_started = False
    for _ in range(50):  # 5 seconds timeout
        time.sleep(0.1)
        # Check for various indicators that recording started
        if (log_capture.contains("Audio ready") or
            log_capture.contains("AudioEngineRecorder started successfully") or
            log_capture.contains("AudioEngine started")):
            latency = (time.time() - start_time) * 1000
            print(f"   ✅ Recording started! Latency: {latency:.0f}ms")
            results["recording_started"] = True
            results["recording_latency_ms"] = latency
            recording_started = True
            break

    if not recording_started:
        print("   ❌ Recording did not start (5s timeout)")
        print("   Recent logs:")
        print(log_capture.get_recent(10))
        results["recording_started"] = False
        results["errors"].append("Recording did not start")
        log_capture.stop()
        return results

    # -------------------------------------------------------------------------
    # Step 5: Record Audio
    # -------------------------------------------------------------------------
    print(f"\n[5/7] Recording for {args.record_duration} seconds...")

    time.sleep(args.record_duration)

    # -------------------------------------------------------------------------
    # Step 6: Stop Recording
    # -------------------------------------------------------------------------
    print("\n[6/7] Stopping recording...")
    stop_time = time.time()
    trigger_hotkey()

    # Wait for transcription to start
    print("   Watching for transcription...")
    transcription_started = False
    for _ in range(100):  # 10 seconds timeout
        time.sleep(0.1)
        if log_capture.contains("Starting transcription"):
            print("   ✅ Transcription started")
            results["transcription_started"] = True
            transcription_started = True
            break

    if not transcription_started:
        print("   ⚠️  Did not detect transcription start")
        results["transcription_started"] = False

    # Wait a bit more for transcription to complete
    print("   Waiting for transcription to complete...")
    time.sleep(5)

    # Check for errors
    if log_capture.contains("Recording error occurred"):
        print("   ❌ Recording error found in logs")
        results["errors"].append("Recording error in logs")

    if log_capture.contains("Transcription Failed"):
        print("   ❌ Transcription failed")
        results["errors"].append("Transcription failed")

    log_capture.stop()

    # -------------------------------------------------------------------------
    # Step 7: Validate Results
    # -------------------------------------------------------------------------
    print("\n[7/7] Validating results...")

    # Check for new WAV file
    after_recording = get_newest_recording()
    after_count = len(get_recordings())

    if after_count > before_count and after_recording != before_recording:
        print(f"   ✅ New recording created: {after_recording.name}")
        results["wav_created"] = True

        # Validate audio format
        audio_info = validate_audio_format(after_recording)
        if audio_info["valid"]:
            print(f"   ✅ Audio format valid: {audio_info['format']}")
            results["audio_format_valid"] = True
        else:
            print(f"   ⚠️  Unexpected audio format: {audio_info.get('format', 'unknown')}")
            results["audio_format_valid"] = False

        if audio_info["duration"]:
            print(f"   ✅ Audio duration: {audio_info['duration']:.2f}s")
            results["audio_duration"] = audio_info["duration"]
    else:
        print("   ❌ No new recording file created")
        results["wav_created"] = False
        results["errors"].append("No WAV file created")

    # Check database
    transcription = get_latest_transcription()
    if transcription:
        print(f"   Database entry found:")
        print(f"      Status: {transcription['status']}")
        print(f"      Text: {transcription['text']}")
        if transcription['audio_duration']:
            print(f"      Audio duration: {transcription['audio_duration']:.2f}s")
        if transcription['transcription_duration']:
            print(f"      Transcription time: {transcription['transcription_duration']:.2f}s")

        if transcription['status'] == 'completed':
            results["transcription_completed"] = True
            print("   ✅ Transcription completed successfully")
        elif transcription['status'] == 'pending':
            results["transcription_completed"] = False
            print("   ⚠️  Transcription still pending")
        else:
            results["transcription_completed"] = False
            print(f"   ❌ Transcription status: {transcription['status']}")
    else:
        print("   ⚠️  Could not query database")

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)

    passed = 0
    failed = 0

    checks = [
        ("App Launch", results["app_launch"]),
        ("Recording Started", results["recording_started"]),
        ("WAV File Created", results["wav_created"]),
        ("Audio Format Valid", results["audio_format_valid"]),
        ("Transcription Started", results["transcription_started"]),
        ("Transcription Completed", results["transcription_completed"]),
    ]

    for name, status in checks:
        if status is True:
            print(f"  ✅ {name}")
            passed += 1
        elif status is False:
            print(f"  ❌ {name}")
            failed += 1
        else:
            print(f"  ⚠️  {name} (unknown)")

    if results["recording_latency_ms"]:
        print(f"\n  Recording latency: {results['recording_latency_ms']:.0f}ms")
    if results["audio_duration"]:
        print(f"  Audio duration: {results['audio_duration']:.2f}s")

    print(f"\n  Passed: {passed}/{len(checks)}")

    if results["errors"]:
        print(f"\n  Errors:")
        for err in results["errors"]:
            print(f"    - {err}")

    print()

    if failed == 0:
        print("✅ VALIDATION PASSED")
        return 0
    else:
        print("❌ VALIDATION FAILED")
        return 1


if __name__ == "__main__":
    sys.exit(main())
