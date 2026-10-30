import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("VAD installation state")
struct VADInstallControllerTests {
    @Test @MainActor func staleVerificationCannotOverwriteNewerVerifiedState() async throws {
        let gate = VADVerificationGate()
        let controller = VADInstallController(verify: { await gate.verify($0) })
        let first = Task { await controller.refresh() }
        try await waitUntilAsync { await gate.pendingCount == 1 }
        let second = Task { await controller.refresh() }
        try await waitUntilAsync { await gate.pendingCount == 2 }
        await gate.complete(index: 1, installed: true)
        await second.value
        #expect(controller.isInstalled)
        await gate.complete(index: 0, installed: false)
        await first.value
        #expect(controller.isInstalled, "An older disk check must not replace the latest verified state")
    }
}

private actor VADVerificationGate {
    private var pending: [CheckedContinuation<Result<URL, Error>, Never>] = []
    var pendingCount: Int { pending.count }

    func verify(_ root: URL) async -> Result<URL, Error> {
        await withCheckedContinuation { pending.append($0) }
    }

    func complete(index: Int, installed: Bool) {
        pending[index].resume(returning: installed
            ? .success(URL(fileURLWithPath: "/synthetic-model")) : .failure(LocalModelError.missingVAD))
    }
}
