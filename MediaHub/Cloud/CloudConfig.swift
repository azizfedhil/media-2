import Foundation

/// Where the Pear cloud Worker is (cloud/README.md, Setup). Set this once the Worker is deployed: it is the base URL of
/// `/health`. Both values point at the same Worker for now. They are separate so either one can move to another host
/// later without touching the other feature. Keep these in step with CloudConfig.kt.
enum CloudConfig {
    /// Pear.pair: accounts, devices, pair codes and sync.
    static let pairBaseURL = URL(string: "https://pear-cloud.azizfedhil5.workers.dev")!
    /// Watch party: rooms and the room WebSocket (batch S2).
    static let partyBaseURL = pairBaseURL
}
