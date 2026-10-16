import Foundation

// Batch S2, watch party logic. Not compiled: the owner's CI builds it.

/// The watch party REST routes (cloud/CLOUD_API.md §3). Rooms are made and looked up here; everything after that runs on the
/// socket. Uses the party base URL, which is separate from Pear.pair so either can move later.
struct PartyAPI {
    let base: URL

    init(base: URL = CloudConfig.partyBaseURL) {
        self.base = base
    }

    private var cloud: CloudClient { CloudClient(base: base) }

    struct CreatedRoom: Sendable {
        let code: String
        let memberId: String
        /// Never logged, never saved to disk.
        let hostToken: String
    }

    struct RoomInfo: Sendable {
        let memberCount: Int
        let locked: Bool
        let full: Bool
    }

    /// Makes a room with this device as host.
    func createRoom(hostName: String) async throws -> CreatedRoom {
        let answer = try await cloud.send("POST", "/v1/party/rooms", body: ["hostName": hostName])
        let code = try answer.string("code")
        let memberId = try answer.string("memberId")
        let hostToken = try answer.string("hostToken")
        return CreatedRoom(code: code, memberId: memberId, hostToken: hostToken)
    }

    /// Whether a room can be joined. A missing room comes back as a 404 `CloudError.rejected`.
    func roomInfo(code: String) async throws -> RoomInfo {
        let answer = try await cloud.send("GET", "/v1/party/rooms/\(code)")
        return RoomInfo(
            memberCount: (answer["memberCount"] as? NSNumber)?.intValue ?? 0,
            locked: answer["locked"] as? Bool ?? false,
            full: answer["full"] as? Bool ?? false
        )
    }

    /// The room's WebSocket address: the same host as the REST routes, on the ws/wss scheme.
    func socketURL(code: String) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = "/v1/party/rooms/\(code)/ws"
        return parts.url
    }
}
