import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Reviewed local model versions")
struct LocalModelVersionTests {
    @Test func metadataCanReportANewerSourceButCannotApproveItsWeights() async throws {
        let model = try #require(LocalSpeechCatalog.models().first)
        let revision = String(repeating: "a", count: 40)
        actor Requests {
            var urls: [URL] = []
            func record(_ url: URL) { urls.append(url) }
        }
        let requests = Requests()
        let checker = LocalModelUpdateChecker(fetch: { url in
            await requests.record(url)
            return Data("{\"sha\":\"\(revision)\"}".utf8)
        })
        let result = try await checker.check(model.manifest)
        #expect(result == .unreviewed(revision))
        let urls = await requests.urls
        #expect(urls.count == 1)
        #expect(urls.first?.host == "huggingface.co")
        #expect(urls.first?.path == "/api/models/\(model.manifest.repository)")
        #expect(urls.first?.query == "expand=sha")
        let catalog = try LocalModelVersionCatalog(preferred: LocalSpeechCatalog.models(), retained: [])
        #expect(catalog.reviewed.first { $0.id == model.id && $0.manifest.revision == revision } == nil)
        #expect(model.manifest.revision != revision)
    }

    @Test(arguments: ["{}", "{\"sha\":\"main\"}", "{\"sha\":\"../outside\"}"])
    func malformedMetadataCannotBecomeAnUpdate(body: String) async throws {
        let model = try #require(LocalSpeechCatalog.models().first)
        let checker = LocalModelUpdateChecker(fetch: { _ in Data(body.utf8) })
        await #expect(throws: LocalModelError.invalidManifest) { try await checker.check(model.manifest) }
    }

    @Test func duplicateOrWrongModeVersionsAreRejected() throws {
        let models = try LocalSpeechCatalog.models(), first = try #require(models.first)
        #expect(throws: LocalModelError.invalidManifest) {
            try LocalModelVersionCatalog(preferred: models, retained: [first])
        }
        let incompatible = LocalSpeechModel(id: first.id, name: first.name, mode: .streaming, manifest: first.manifest)
        #expect(throws: LocalModelError.invalidManifest) {
            try LocalModelVersionCatalog(preferred: models, retained: [incompatible])
        }
    }
}
