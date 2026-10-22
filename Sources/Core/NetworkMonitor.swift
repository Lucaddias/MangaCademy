import Foundation
import Network

/// Tipo de conexão atual (para "só no Wi‑Fi" no pré-carregamento, downloads e atualizações).
public final class NetworkMonitor: @unchecked Sendable {
    public static let shared = NetworkMonitor()
    /// A conexão mudou (ex.: entrou no Wi‑Fi).
    public static let changed = Notification.Name("NetworkMonitorChanged")

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.path = path
            self.lock.unlock()
            NotificationCenter.default.post(name: NetworkMonitor.changed, object: nil)
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return path?.status != .unsatisfied
    }

    /// Wi‑Fi ou cabo (sem dados móveis nem conexão limitada).
    public var isOnWifi: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let path else { return true }
        return path.status == .satisfied && !path.isExpensive && !path.isConstrained
    }
}
