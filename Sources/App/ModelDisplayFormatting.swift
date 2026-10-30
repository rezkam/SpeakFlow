import Foundation

enum ModelDisplayFormatting {
    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: bytes)
    }
}
