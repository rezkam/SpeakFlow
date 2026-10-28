import Foundation
import SpeakFlowCore

/// Import only an explicitly selected credentials export into the ephemeral store.
/// There is deliberately no fallback to an installed app, keychain, or CLI login.
@MainActor
enum IsolatedAuthBootstrap {
    enum Failure: Error { case refused }

    static func apply(arguments: [String], environment: [String: String]) throws {
        let flags = arguments.indices.filter { arguments[$0] == "--auth-file" }
        guard flags.count <= 1 else { throw Failure.refused }
        var path = environment["SPEAKFLOW_E2E_AUTH_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        if let index = flags.first {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), path == nil else {
                throw Failure.refused
            }
            path = arguments[index + 1]
        }
        guard let path else { return }
        guard RuntimeIsolation.current.isIsolated, !arguments.contains("--silence-only") else {
            throw Failure.refused
        }
        do {
            let credentials = try JSONDecoder().decode(OAuthCredentials.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard !credentials.accessToken.isEmpty, !credentials.refreshToken.isEmpty, !credentials.accountId.isEmpty else {
                throw Failure.refused
            }
            try OpenAICodexAuth.saveCredentials(credentials)
        } catch {
            // Do not print paths, credential contents, or decoder errors.
            throw Failure.refused
        }
    }
}

#if DEBUG
private actor BootstrapNetworkTripwire: HTTPDataProvider {
    private(set) var requests = 0
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        throw CancellationError()
    }
}

extension IsolatedAuthBootstrap {
    static func probe(arguments: [String], environment: [String: String]) async -> Int32 {
        let tripwire = BootstrapNetworkTripwire()
        OpenAICodexAuth.httpProvider = tripwire
        do {
            try apply(arguments: arguments, environment: environment)
            let loggedIn = OpenAICodexAuth.isLoggedIn
            let requests = await tripwire.requests
            print("AUTH_BOOTSTRAP logged_in=\(loggedIn) requests=\(requests)")
            return requests == 0 ? 0 : 1
        } catch {
            print("Authentication bootstrap refused")
            return 1
        }
    }
}
#endif
