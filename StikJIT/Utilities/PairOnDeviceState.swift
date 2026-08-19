import Foundation

enum PairOnDevicePhase: Equatable {
    case idle
    case advertising
    case deviceConnected
    case awaitingPIN(String)
    case succeeded
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .advertising, .deviceConnected, .awaitingPIN:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }
}
