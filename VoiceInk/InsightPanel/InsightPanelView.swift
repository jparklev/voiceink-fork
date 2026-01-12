import SwiftUI

/// Simplified InsightPanelView - now only displays errors
/// Agent responses go directly to Ghostty terminal
struct InsightPanelView: View {
    @StateObject private var controller = InsightPanelController.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("VoiceInk Error")
                    .font(.headline)
                Spacer()

                Button(action: { controller.dismiss() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content - only errors now
            if case .error(let message) = controller.state {
                Text(message)
                    .foregroundStyle(.red)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
    }
}
