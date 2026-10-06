import Foundation
import Network
import Observation

/// Always-on reachability for the offline start and the downloader.
/// `isOnline` is nil until the first path update arrives (a few ms after launch).
@MainActor @Observable
final class Connectivity {
    static let shared = Connectivity()
    private(set) var isOnline: Bool?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "connectivity", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }

    /// Waits (max ~1.5 s) for the first path so a fresh launch doesn't read "offline" by mistake.
    func ready() async -> Bool {
        var waited = 0
        while isOnline == nil && waited < 15 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        return isOnline ?? true
    }
}
