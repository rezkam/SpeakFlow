import Foundation
import OSLog

/// Parses binary cookies from system storage
enum Cookies {
    // Security limits
    private static let maxFileSize = 10_000_000  // 10MB max
    private static let maxPages = 1000
    private static let maxCookiesPerPage = 10000
    private static let maxStringLength = 10000

    // Binary cookie file format constants
    private static let magicHeader = "cook"
    private static let minimumFileSize = 8  // Magic (4) + numPages (4)
    private static let pageHeaderBytes: [UInt8] = [0, 0, 1, 0]
    private static let cookieRecordMinSize = 48

    // Expected cookie file location (OpenAI desktop app)
    private static let cookieFilePath = "Library/HTTPStorages/com.openai.chat.binarycookies"

    static func load() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(cookieFilePath)

        // Check file exists before attempting to read
        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.app.debug("Cookie file not found at \(cookieFilePath) - OpenAI app may not be installed")
            return [:]
        }

        // Get file size before loading
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int else {
            Logger.app.warning("Could not read cookie file attributes")
            return [:]
        }

        guard fileSize > minimumFileSize else {
            Logger.app.debug("Cookie file too small (\(fileSize) bytes)")
            return [:]
        }

        guard fileSize <= maxFileSize else {
            Logger.app.warning("Cookie file exceeds size limit (\(fileSize) > \(maxFileSize))")
            return [:]
        }

        guard let data = try? Data(contentsOf: url) else {
            Logger.app.warning("Could not read cookie file data")
            return [:]
        }

        // Parse to temporary dictionary - only return on complete success
        return parseCookies(from: data) ?? [:]
    }

    /// Parse cookies from binary data, returns nil on any parse error
    private static func parseCookies(from data: Data) -> [String: String]? {
        // Verify magic header
        guard data.count > minimumFileSize,
              data[0..<4].elementsEqual(magicHeader.utf8) else {
            return nil
        }

        // Safe read helpers with bounds checking
        func readUInt32BE(at offset: Int) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            return data[offset..<offset+4].withUnsafeBytes { ptr in
                guard ptr.count >= 4 else { return nil }
                return ptr.loadUnaligned(as: UInt32.self).bigEndian
            }
        }

        func readUInt32LE(at offset: Int) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            return data[offset..<offset+4].withUnsafeBytes { ptr in
                guard ptr.count >= 4 else { return nil }
                return ptr.loadUnaligned(as: UInt32.self).littleEndian
            }
        }

        // Safe addition to prevent integer overflow
        func safeAdd(_ left: Int, _ right: Int) -> Int? {
            let (result, overflow) = left.addingReportingOverflow(right)
            return overflow ? nil : result
        }

        func safeAdd(_ left: Int, _ right: UInt32) -> Int? {
            guard right <= Int.max else { return nil }
            return safeAdd(left, Int(right))
        }

        guard let numPages = readUInt32BE(at: 4),
              numPages <= maxPages else { return nil }

        var offset = 8
        var pageSizes: [Int] = []

        for _ in 0..<numPages {
            guard let size = readUInt32BE(at: offset),
                  size > 0,
                  size <= data.count else { break }
            pageSizes.append(Int(size))
            offset += 4
        }

        // Temporary dictionary for atomic assignment
        var tempCookies = [String: String]()

        for pageSize in pageSizes {
            guard let pageEnd = safeAdd(offset, pageSize),
                  pageEnd <= data.count else { break }

            let pageData = data[offset..<pageEnd]
            let pageStart = pageData.startIndex

            // Check page header
            guard pageData.count > minimumFileSize else { offset += pageSize; continue }
            guard pageData[pageStart..<pageStart+4].elementsEqual(pageHeaderBytes) else {
                offset += pageSize
                continue
            }

            guard let numCookies = readUInt32LE(at: offset + 4),
                  numCookies <= maxCookiesPerPage else {
                offset += pageSize
                continue
            }

            var cookieOffset = 8
            for _ in 0..<numCookies {
                guard cookieOffset + 4 <= pageSize else { break }
                guard let cookieStart = readUInt32LE(at: offset + cookieOffset) else { break }
                cookieOffset += 4

                // Safe calculation of cookie base with overflow protection
                guard let cookieBase = safeAdd(offset, cookieStart),
                      let cookieEnd = safeAdd(cookieBase, cookieRecordMinSize),
                      cookieBase >= 0,
                      cookieEnd <= data.count else { continue }

                // Read string offsets from cookie record
                guard let domainOffset = readUInt32LE(at: cookieBase + 16),
                      let nameOffset = readUInt32LE(at: cookieBase + 20),
                      let valueOffset = readUInt32LE(at: cookieBase + 28) else { continue }

                func readString(at strOffset: UInt32) -> String? {
                    // Safe position calculation with overflow check
                    guard let pos = safeAdd(cookieBase, strOffset),
                          pos >= 0,
                          pos < data.count else { return nil }

                    // Find null terminator with length limit
                    var end = pos
                    let maxEnd = min(data.count, pos + maxStringLength)
                    while end < maxEnd && data[end] != 0 { end += 1 }

                    guard end > pos else { return nil }
                    return String(data: data[pos..<end], encoding: .utf8)
                }

                if let domain = readString(at: domainOffset),
                   let name = readString(at: nameOffset),
                   let value = readString(at: valueOffset),
                   domain.contains("chatgpt.com") {
                    tempCookies[name] = value
                }
            }
            offset += pageSize
        }

        return tempCookies
    }
}
