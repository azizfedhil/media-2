import Foundation

// Batch S2, watch party logic. Not compiled: the owner's CI builds it.

/// Time for the party code: Unix ms for the wire, a monotonic clock in seconds for timers.
enum PartyTime {
    static var unixMs: Double { Date().unixMs }
    static var monotonic: Double { ProcessInfo.processInfo.systemUptime }
}

/// Server time estimated from ping/pong (plan section 5): the three samples with the shortest round trip, and the median
/// of their offsets. `serverNow ≈ clientNow + offset`. Until the first pong the offset is 0.
struct PartyClock {
    private struct Sample {
        let rtt: Double
        let offset: Double
    }

    private var samples: [Sample] = []
    private(set) var offset: Double = 0

    /// `clientMs` is when the ping left (echoed back by the server), `serverMs` the server's time in its pong.
    mutating func addPong(sentAt clientMs: Double, serverAt serverMs: Double, receivedAt receivedMs: Double) {
        let rtt = max(0, receivedMs - clientMs)
        guard rtt < 5_000 else { return } // a stalled round trip says nothing about the clock
        samples.append(Sample(rtt: rtt, offset: serverMs - (clientMs + rtt / 2)))
        if samples.count > 8 { samples.removeFirst(samples.count - 8) }
        let best = samples.sorted { $0.rtt < $1.rtt }.prefix(3).map(\.offset)
        offset = Self.median(best)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
