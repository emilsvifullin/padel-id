import Foundation

/// Build-time environment. Release builds always talk to the production API;
/// only Debug builds (used by UI tests) accept an override.
nonisolated enum AppEnvironment {
    static let productionAPI = URL(string: "https://padel-id-gamma.vercel.app")!

    static var apiBaseURL: URL {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["PADELID_API_URL"], let url = URL(string: raw) {
            return url
        }
        #endif
        return productionAPI
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// UI tests start every run from a clean state.
    static var shouldResetState: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-resetState")
        #else
        return false
        #endif
    }

    static var isUITesting: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PADELID_API_URL"] != nil
        #else
        return false
        #endif
    }
}
