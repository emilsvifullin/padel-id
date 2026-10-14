import Foundation

/// Build-time environment. Release builds always talk to the production API;
/// only Debug builds (used by UI tests) accept an override.
nonisolated enum AppEnvironment {
    /// Enabled only in a build signed with an APNs-enabled provisioning profile.
    static var remotePushEnabled: Bool {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PadelIDRemotePushEnabled")
        if let value = raw as? Bool { return value }
        return ["YES", "TRUE", "1"].contains((raw as? String ?? "").uppercased())
    }
    static let productionAPI: URL = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PadelIDAPIBaseURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.host() != nil,
              url.user == nil, url.password == nil else {
            preconditionFailure("Missing or invalid build-time production API origin")
        }
        return url
    }()

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

    /// Other origins of the same gateway, empty in the shipped build. With any
    /// set, the route selector probes each one. The client never calls
    /// Supabase Auth or Data API directly.
    static var apiFallbackURLs: [URL] {
        if isUITesting { return [] }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PadelIDAPIFallbackURL") as? String else { return [] }
        return fallbackURLs(from: raw)
    }

    /// One or more origins separated by spaces. A build with an invalid entry
    /// must not start: it would silently lose a route.
    static func fallbackURLs(from raw: String) -> [URL] {
        raw.split(whereSeparator: \.isWhitespace).map { entry in
            guard let url = URL(string: String(entry)), url.scheme == "https", url.host() != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                preconditionFailure("Invalid build-time gateway fallback URL")
            }
            return url
        }
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
