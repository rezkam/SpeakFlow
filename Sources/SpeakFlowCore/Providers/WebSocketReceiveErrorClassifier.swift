import Darwin
import Foundation

/// Classifies receive errors that represent an ended WebSocket connection.
///
/// URLSessionWebSocketTask reports remote close frames and some socket disconnects
/// as receive errors on Darwin. Routing these cases as `.closed` lets the streaming
/// lifecycle attempt recovery instead of treating them as terminal provider errors.
enum WebSocketReceiveErrorClassifier {
    static func shouldRouteAsClosed(_ error: Error) -> Bool {
        if error is CancellationError { return true }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNetworkConnectionLost,
                 NSURLErrorCancelled:
                return true
            default:
                return false
            }
        }

        return nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(ECONNRESET)
    }
}
