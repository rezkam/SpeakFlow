import Foundation

/// Bounded Unicode payloads for completed batch results.
enum BatchTextPayload {
    // Conservative event payload size. Keep complete graphemes together when they fit.
    static let maxUTF16Length = 20

    static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var pending = ""
        var length = 0
        func append(_ piece: String) {
            let count = piece.utf16.count
            if length + count > maxUTF16Length, !pending.isEmpty {
                result.append(pending)
                pending = ""
                length = 0
            }
            pending += piece
            length += count
        }
        for character in text {
            let piece = String(character)
            if piece.utf16.count <= maxUTF16Length {
                append(piece)
            } else {
                // An oversized grapheme still preserves every scalar and surrogate pair.
                for scalar in piece.unicodeScalars { append(String(scalar)) }
            }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }
}
