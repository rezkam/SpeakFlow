import Darwin
import Foundation

/// Child test runners must load the active sanitizer before loading an instrumented test bundle.
enum TestProcessEnvironment {
    static func inherited() throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard let process = dlopen(nil, RTLD_NOW) else { throw LaunchError.runtimeLookup }
        defer { dlclose(process) }
        guard let sanitizer = dlsym(process, "__tsan_init") else { return environment }
        var library = Dl_info()
        guard dladdr(sanitizer, &library) != 0, let name = library.dli_fname else {
            throw LaunchError.runtimeLookup
        }
        let path = String(cString: name)
        let existing = environment["DYLD_INSERT_LIBRARIES"]?.split(separator: ":").map(String.init) ?? []
        environment["DYLD_INSERT_LIBRARIES"] = ([path] + existing.filter { $0 != path }).joined(separator: ":")
        return environment
    }

    private enum LaunchError: Error { case runtimeLookup }
}
