import SwiftUI
import Foundation

nonisolated struct NetworkProbe: Sendable {
    let title: String
    let status: Int?
    let code: Int?
    let errorDomain: String?
    let apiOK: Bool
    let requestId: String?
    let seconds: Double
    let databaseOK: Bool?
    var summary: String {
        if let code { return "\(errorDomain ?? "Ошибка") \(code)" }
        guard let status else { return "Нет HTTP-ответа" }
        guard apiOK else { return "HTTP \(status), ответ API не подтверждён" }
        if let databaseOK { return "HTTP \(status), база: \(databaseOK ? "доступна" : "не подтверждена")" }
        return "HTTP \(status)"
    }
}

@Observable
final class NetworkDiagnostics {
    private(set) var probes: [NetworkProbe] = []
    private(set) var isRunning = false
    private(set) var checkedAt: Date?
    private let baseURLs: [URL]
    private let session: URLSession

    init(baseURL: URL = AppEnvironment.apiBaseURL, session: URLSession? = nil, fallbackURLs: [URL]? = nil) {
        let fallback = fallbackURLs ?? (baseURL == AppEnvironment.apiBaseURL ? AppEnvironment.apiFallbackURLs : [])
        self.baseURLs = [baseURL] + fallback.filter { $0 != baseURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: GatewayRedirectPolicy(), delegateQueue: nil)
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        probes = []
        checkedAt = .now
        defer { isRunning = false }
        for baseURL in baseURLs {
            if Task.isCancelled { return }
            await check(baseURL)
        }
    }

    private func check(_ baseURL: URL) async {
        for deep in [false, true] {
            guard !Task.isCancelled else { return }
            var components = URLComponents(url: baseURL.appending(path: "v1/health"), resolvingAgainstBaseURL: false)!
            if deep { components.queryItems = [URLQueryItem(name: "deep", value: "1")] }
            let request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
            let start = Date.now
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let apiOK = http?.url == request.url && http?.statusCode == 200 && body?["status"] as? String == "ok"
                    && (http?.value(forHTTPHeaderField: "content-type")?.lowercased().contains("application/json") == true)
                probes.append(NetworkProbe(title: title(deep: deep, route: baseURL),
                    status: http?.statusCode, code: nil, errorDomain: nil, apiOK: apiOK,
                    requestId: http?.value(forHTTPHeaderField: "x-request-id"),
                    seconds: Date.now.timeIntervalSince(start), databaseOK: deep ? (body?["database"] as? String == "ok") : nil))
            } catch {
                if Task.isCancelled { return }
                probes.append(NetworkProbe(title: title(deep: deep, route: baseURL),
                    status: nil, code: (error as NSError).code, errorDomain: (error as NSError).domain, apiOK: false, requestId: nil,
                    seconds: Date.now.timeIntervalSince(start), databaseOK: nil))
                // Gateway failure provides no evidence about database reachability.
                break
            }
        }
    }

    private func title(deep: Bool, route: URL) -> String {
        let label = deep ? "API → база данных" : "iPhone → API"
        return baseURLs.count > 1 ? "\(route.host() ?? "API"): \(label)" : label
    }

    func report(lastFailure: TransportFailure?) -> String {
        var lines = ["Padel ID \(AppEnvironment.version) (\(AppEnvironment.buildNumber))",
                     "iOS \(UIDevice.current.systemVersion)"]
        lines += baseURLs.map { "API: \($0.absoluteString)" }
        if let checkedAt { lines.append("Проверка: \(checkedAt.ISO8601Format())") }
        if let lastFailure {
            lines.append("Последний сбой: \(lastFailure.path), \(lastFailure.domain) \(lastFailure.code), \(lastFailure.date.ISO8601Format())")
        }
        for probe in probes {
            lines.append("\(probe.title): \(probe.summary), \(String(format: "%.2f", probe.seconds)) c")
            if let id = probe.requestId { lines.append("request-id: \(id)") }
        }
        return lines.joined(separator: "\n")
    }
}

struct NetworkDiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @State private var diagnostics = NetworkDiagnostics()
    var body: some View {
        List {
            Section {
                Text("Проверка помогает определить, достигают ли запросы API и базы данных. Она не отправляет почту, пароль или данные профиля.")
                Button("Проверить соединение") { Task { await diagnostics.run() } }
                    .disabled(diagnostics.isRunning)
                    .accessibilityIdentifier("network.check")
                if diagnostics.isRunning { ProgressView("Проверяем…") }
            }
            if !diagnostics.probes.isEmpty {
                Section("Результаты") {
                    ForEach(Array(diagnostics.probes.enumerated()), id: \.offset) { _, probe in
                        LabeledContent(probe.title, value: probe.summary)
                    }
                    Text(diagnostics.report(lastFailure: app.api.lastTransportFailure))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink("Поделиться результатами", item: diagnostics.report(lastFailure: app.api.lastTransportFailure))
                }
            }
            Section("Проверка без VPN") {
                Text("Выключите VPN и выполните проверку сначала через домашний Wi-Fi, затем через мобильную сеть. Укажите сеть и оператора вместе с результатами.")
                Text("Успешная проверка соединения не заменяет регистрацию, вход и остальные сценарии приложения.")
                    .foregroundStyle(.secondary)
            }
        }.closeToBar()
        .navigationTitle("Проверка сети")
        .navigationBarTitleDisplayMode(.inline)
    }
}
