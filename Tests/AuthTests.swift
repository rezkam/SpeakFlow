import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - OAuthCallbackServer Tests

struct OAuthCallbackServerTests {
    
    @Test("Cancellation correctly resumes continuation")
    func testCancellationResumesContinuation() async {
        let server = OAuthCallbackServer(expectedState: "test-state")
        
        let task = Task {
            await server.waitForCallback(timeout: 60)
        }
        
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        
        let result = await Task {
            await withTaskGroup(of: String?.self) { group in
                group.addTask { await task.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return "timeout"
                }
                let first = await group.next()
                group.cancelAll()
                return first ?? "timeout"
            }
        }.value
        
        #expect(result != "timeout", "Cancellation completes without hanging")
    }
}

// MARK: - OAuth State Validation Tests

struct OAuthStateValidationTests {
    
    /// Simulates the logic from AppDelegate.promptForManualCode
    private func extractCode(_ inputValue: String, expectedState: String) -> String? {
        if let url = URL(string: inputValue),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value {
            if let stateParam = components.queryItems?.first(where: { $0.name == "state" })?.value {
                guard stateParam == expectedState else {
                    return nil
                }
            }
            return codeParam
        }
        return inputValue
    }
    
    @Test("URLs with wrong state are rejected")
    func testWrongStateRejected() {
        let expectedState = "legitimate-state-12345"
        let maliciousURL = "http://localhost:1455/auth/callback?code=stolen-code&state=attacker-controlled"
        
        let result = extractCode(maliciousURL, expectedState: expectedState)
        
        #expect(result == nil, "URLs with mismatched state should be rejected")
    }
    
    @Test("URLs with correct state are accepted")
    func testCorrectStateAccepted() {
        let expectedState = "legitimate-state-12345"
        let validURL = "http://localhost:1455/auth/callback?code=valid-code&state=legitimate-state-12345"
        
        let result = extractCode(validURL, expectedState: expectedState)
        
        #expect(result == "valid-code", "URLs with matching state should be accepted")
    }
    
    @Test("Plain code without URL still works")
    func testPlainCodeStillWorks() {
        let plainCode = "authorization-code-12345"
        
        let result = extractCode(plainCode, expectedState: "any-state")
        
        #expect(result == plainCode, "Plain codes should still be accepted")
    }
}

// MARK: - Credential Parsing Tests

struct CredentialParsingTests {
    
    /// Simulates the logic from OpenAICodexAuth.loadCredentials
    private func parseLastRefresh(_ dateString: String) -> Date {
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso8601Formatter.date(from: dateString) ?? Date.distantPast
    }
    
    @Test("Invalid date forces refresh")
    func testInvalidDateForcesRefresh() {
        let invalidDateString = "corrupted-garbage-not-a-date"
        
        let parsedDate = parseLastRefresh(invalidDateString)
        let shouldRefresh = Date().timeIntervalSince(parsedDate) > 86400
        
        #expect(shouldRefresh, "Invalid date should trigger refresh by returning distant past")
    }
    
    @Test("Empty date forces refresh")
    func testEmptyDateForcesRefresh() {
        let emptyDateString = ""
        
        let parsedDate = parseLastRefresh(emptyDateString)
        let shouldRefresh = Date().timeIntervalSince(parsedDate) > 86400
        
        #expect(shouldRefresh, "Empty date should trigger refresh")
    }
    
    @Test("Valid date is parsed correctly")
    func testValidDateParsedCorrectly() {
        let validDateString = "2024-01-15T10:30:00.000Z"
        
        let parsedDate = parseLastRefresh(validDateString)
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: parsedDate)
        #expect(components.year == 2024, "Year should be parsed correctly")
        #expect(components.month == 1, "Month should be parsed correctly")
        #expect(components.day == 15, "Day should be parsed correctly")
    }
}

// MARK: - AuthCredentials Symlink Detection Tests

struct AuthCredentialsTests {
    
    @Test("Symlinks are detected correctly")
    func testSymlinkDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let realFile = tempDir.appendingPathComponent("test_auth_real_\(UUID().uuidString).json")
        let symlinkFile = tempDir.appendingPathComponent("test_auth_symlink_\(UUID().uuidString).json")
        
        let authJson = """
        {
            "tokens": {
                "access_token": "test_token",
                "account_id": "test_account"
            }
        }
        """
        try authJson.write(to: realFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)
        
        defer {
            try? FileManager.default.removeItem(at: realFile)
            try? FileManager.default.removeItem(at: symlinkFile)
        }
        
        let attrs = try FileManager.default.attributesOfItem(atPath: symlinkFile.path)
        let fileType = attrs[.type] as? FileAttributeType
        #expect(fileType == .typeSymbolicLink, "Symlink should be detected")
        
        let realAttrs = try FileManager.default.attributesOfItem(atPath: realFile.path)
        let realType = realAttrs[.type] as? FileAttributeType
        #expect(realType != .typeSymbolicLink, "Real file should not be a symlink")
    }
}
