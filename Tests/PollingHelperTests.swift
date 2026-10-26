import Testing

@Suite("Polling helper contracts")
struct PollingHelperTests {
    @Test(arguments: [false, true]) @MainActor
    func unmetConditionThrows(useAsync: Bool) async throws {
        var threw = false
        do {
            if useAsync {
                try await waitUntilAsync(timeout: .milliseconds(5), interval: .milliseconds(1)) { false }
            } else {
                try await waitUntil(timeout: .milliseconds(5), interval: .milliseconds(1)) { false }
            }
        } catch {
            #expect(error is PollingError)
            threw = true
        }
        #expect(threw, "A timeout must fail the test instead of silently satisfying its precondition")
    }

    @Test(arguments: [false, true]) @MainActor
    func satisfiedConditionReturnsImmediately(useAsync: Bool) async throws {
        if useAsync {
            try await waitUntilAsync(timeout: .seconds(1)) { true }
        } else {
            try await waitUntil(timeout: .seconds(1)) { true }
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func cancellationIsNotReportedAsSuccess(useAsync: Bool) async throws {
        let task = Task { @MainActor in
            if useAsync { try await waitUntilAsync { true } }
            else { try await waitUntil { true } }
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled polling must throw, even when the condition is already true")
        } catch { #expect(error is CancellationError) }
    }
}
