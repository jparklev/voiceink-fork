import AppKit
import Testing
@testable import VoiceInk

// The test host shares the app's defaults, so save and restore any key a test sets.
func withDefaults(_ values: [String: Any], _ body: () async throws -> Void) async rethrows {
    let saved = values.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    values.forEach { UserDefaults.standard.set($1, forKey: $0) }
    defer { saved.forEach { UserDefaults.standard.set($1, forKey: $0) } }
    try await body()
}

@MainActor
struct CursorPasterTests {
    @Test func keepsTranscriptOnClipboardWhenAccessibilityIsMissing() async throws {
        CursorPaster.isAccessibilityTrusted = { false }
        defer { CursorPaster.isAccessibilityTrusted = { AXIsProcessTrusted() } }
        try await withDefaults(["restoreClipboardAfterPaste": true, "clipboardRestoreDelay": 0.25, "useAppleScriptPaste": false]) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("copied earlier", forType: .string)

            await CursorPaster.startPasteAtCursor("Test one, two.").value
            try await Task.sleep(for: .seconds(0.6))

            #expect(NSPasteboard.general.string(forType: .string) == "Test one, two.")
        }
    }
}
