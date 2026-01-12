import SwiftUI

struct ThinkingPillView: View {
    @State private var animating = false

    var body: some View {
        HStack {
            Circle()
                .fill(.purple.opacity(0.6))
                .frame(width: 8, height: 8)
                .scaleEffect(animating ? 1.2 : 0.8)
            Circle()
                .fill(.purple.opacity(0.6))
                .frame(width: 8, height: 8)
                .scaleEffect(animating ? 0.8 : 1.2)
            Circle()
                .fill(.purple.opacity(0.6))
                .frame(width: 8, height: 8)
                .scaleEffect(animating ? 1.2 : 0.8)
        }
        .padding(20)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                animating = true
            }
        }
    }
}
