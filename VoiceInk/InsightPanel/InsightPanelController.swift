import AppKit
import SwiftUI

/// Simplified InsightPanelController - now only used for error display
/// Since we always use agent mode (Ghostty terminal), responses go directly to the terminal
@MainActor
class InsightPanelController: ObservableObject {
    static let shared = InsightPanelController()

    private var panel: NSPanel?
    @Published var state: InsightPanelState = .idle

    /// Show an error message in the panel
    func showError(_ message: String) {
        if panel == nil {
            createPanel()
        }
        state = .error(message: message)
        panel?.orderFront(nil)
        positionPanel()

        // Auto-dismiss after 10 seconds
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if case .error = state {
                dismiss()
            }
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        state = .idle
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // SwiftUI view handles shadow

        let hostingView = NSHostingView(rootView: InsightPanelView())
        panel.contentView = hostingView

        self.panel = panel
    }

    private func positionPanel() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame

        let x = screenFrame.maxX - panelFrame.width - 20
        let y = screenFrame.maxY - panelFrame.height - 20

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
