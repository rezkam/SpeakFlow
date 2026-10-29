import Foundation

/// Opt-in local update verification. Distribution builds cannot enable this mode.
enum UpdateVerification {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SPEAKFLOW_UPDATE_VERIFICATION"] == "1"
            && ProcessInfo.processInfo.environment["SPEAKFLOW_ISOLATED_STORAGE"] == "1"
        #else
        false
        #endif
    }

    static func acceptsFeed(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        if url.scheme == "https" { return true }
        return isEnabled && url.scheme == "http" && host == "localhost"
    }
}
