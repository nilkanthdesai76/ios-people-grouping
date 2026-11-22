import Dispatch
import Foundation
import Network

/// Observes connectivity. Only reads the path; performs no networking itself.
actor NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.peoplegrouping.networkmonitor")
    private var satisfied = true
    private var wifi = false
    private var constrained = false
    private var didUpdate = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.update(path: path) }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// Until the first path update arrives, allow downloads so startup is never blocked.
    func isCloudDownloadAllowed(wifiOnly: Bool) -> Bool {
        guard didUpdate else { return true }
        guard satisfied, !constrained else { return false }
        if wifiOnly { return wifi }
        return true
    }

    private func update(path: NWPath) {
        satisfied = path.status == .satisfied
        wifi = path.usesInterfaceType(.wifi)
        constrained = path.isConstrained
        didUpdate = true
    }
}
