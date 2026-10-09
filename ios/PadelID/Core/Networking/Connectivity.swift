import Foundation
import Network
import Observation

/// Observes network reachability (NWPathMonitor delivers on the main queue).
@Observable
final class Connectivity {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private var onReconnect: [() -> Void] = []

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.update(path.status == .satisfied)
            }
        }
        monitor.start(queue: .main)
    }

    func whenReconnected(_ action: @escaping () -> Void) {
        onReconnect.append(action)
    }

    private func update(_ online: Bool) {
        let wasOffline = !isOnline
        isOnline = online
        if online && wasOffline {
            onReconnect.forEach { $0() }
        }
    }
}
