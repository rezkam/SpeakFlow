import FluidAudio
import Testing

@Suite("Release dependency isolation")
struct ReleaseDependencyTests {
    @Test func unusedNativeTextEngineIsNotLinked() {
        #expect(!TextNormalizer.shared.isNativeAvailable,
                "VAD-only usage must not link the unused prebuilt text engine and its build paths")
    }
}
