import Foundation

/// Platform support detection for VAD features
public enum PlatformSupport {
    public static var supportsVAD: Bool { isAppleSilicon }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static var platformDescription: String {
        isAppleSilicon ? "Apple Silicon" : "Intel"
    }

    public static var vadUnavailableReason: String? {
        isAppleSilicon ? nil : "Voice Activity Detection requires Apple Silicon (M1 or later)"
    }
}
