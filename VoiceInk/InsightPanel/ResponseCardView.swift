import SwiftUI

struct ResponseCardView: View {
    let text: String
    
    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
