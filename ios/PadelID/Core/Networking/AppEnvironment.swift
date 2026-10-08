import Foundation

/// Build-time environment. Release builds always talk to the production API;
/// only Debug builds (used by UI tests) accept an override.
nonisolated enum AppEnvironment {
    static let productionAPI = URL(string: "https://padel-id-gamma.vercel.app")!

    #if DEBUG
    /// Debug-only test hooks (long names so the release check can find them).
    static let uiTestAPIKey = "PADELID_UITEST_API_BASE_URL"
    static let uiTestResetArgument = "-padelid-uitest-reset-state"
    #endif

    static var apiBaseURL: URL {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment[uiTestAPIKey], let url = URL(string: raw) {
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
        return ProcessInfo.processInfo.arguments.contains(uiTestResetArgument)
        #else
        return false
        #endif
    }

    static var isUITesting: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment[uiTestAPIKey] != nil
        #else
        return false
        #endif
    }
}
