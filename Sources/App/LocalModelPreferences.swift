import Foundation
import Observation
import SpeakFlowCore

@MainActor @Observable
final class LocalModelPreferences {
    static let shared = LocalModelPreferences()
    private let defaults = RuntimeIsolation.current.makeDefaults(prefix: "speakflow.local-models.tests")
    var preloadOnLaunch: Bool {
        didSet { defaults.set(preloadOnLaunch, forKey: "localModels.preloadOnLaunch") }
    }
    var idleSeconds: Int {
        didSet { defaults.set(idleSeconds, forKey: "localModels.idleSeconds") }
    }
    private init() {
        preloadOnLaunch = defaults.bool(forKey: "localModels.preloadOnLaunch")
        idleSeconds = defaults.object(forKey: "localModels.idleSeconds") == nil ? 300 : defaults.integer(forKey: "localModels.idleSeconds")
    }
}
