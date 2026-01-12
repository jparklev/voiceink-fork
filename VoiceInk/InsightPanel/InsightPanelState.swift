import Foundation

/// Simplified InsightPanel state - now only used for errors since we always use agent mode
enum InsightPanelState: Equatable {
    case idle
    case error(message: String)

    var isVisible: Bool {
        switch self {
        case .idle: return false
        case .error: return true
        }
    }
}
