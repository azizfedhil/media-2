import Foundation
import Observation

// Batch S2, watch party logic. Not compiled: the owner's CI builds it.

/// Where this device stands in a watch party. The room screens show these.
enum PartyPhase: Equatable {
    case idle
    case connecting
    case inRoom
    /// The connection dropped and is being retried with backoff.
    case reconnecting
    /// The room is over for this device. `reason` is the server's word: ended, kicked, expired, full, locked or gone.
    case ended(reason: String)
    /// Not usable right now (free-plan quota, or the service can't be reached). Nothing retries in a loop; the user tries again.
    case unavailable(message: String)
}

/// Gets the room's state. One listener at a time: the adapter for the player that is open.
@MainActor
protocol PartyRoomListener: AnyObject {
    /// Every state the room sends, and the state in a welcome.
    func partyStateChanged(_ state: PartyState)
    /// The room is over for this device.
    func partyRoomEnded()
}

enum PartyText {
    static let quota = "Watch party is unavailable right now, try again later"
    static let unreachable = "Can't reach watch party right now. Check your connection and try again."
    static let noRoom = "No party with that code."
    static let full = "This party is full."
    static let locked = "The host has locked this party."

    static func reason(_ reason: String) -> String {
        switch reason {
        case "ended": return "The host ended the party."
        case "kicked": return "The host removed you from the party."
        case "expired": return "The party closed after a long pause."
        case "full": return full
        case "locked": return locked
        default: return "This party is no longer running."
        }
    }
}

/// Seconds to wait before reconnect attempt 1, 2, 3...: 1, 2, 4, 8, then 15 for every later attempt.
enum PartyBackoff {
    static func seconds(forAttempt attempt: Int) -> Double {
        let steps: [Double] = [1, 2, 4, 8, 15]
        return steps[min(max(attempt, 1), steps.count) - 1]
    }
}

/// This device's one party connection: the room it is in (as host or guest), who is in it, the room's playback, and the
/// commands that the room screens and the player adapters send. Owned by `PartySession.shared`.
@MainActor @Observable
final class PartySession {
    static let shared = PartySession()

    private(set) var phase: PartyPhase = .idle
    private(set) var code: String?
    /// "host" or "guest", as the server's welcome says. Nil outside a room.
    private(set) var role: String?
    private(set) var memberId: String?
    private(set) var members: [PartyMember] = []
    private(set) var state: PartyState?
    private(set) var suggestions: [PartySuggestion] = []
    /// Guest requests waiting for the host. Each lapses after 30 seconds. Host only.
    private(set) var requests: [PartyRequest] = []
    private(set) var autoApprove = false
    private(set) var locked = false
    /// The last line worth showing: a server error, or why the room ended.
    private(set) var notice: String?

    /// The listener for the open player: the host or guest adapter.
    @ObservationIgnored weak var listener: PartyRoomListener?
    /// Server time of this device's latest command. A state older than this is an echo of something already overtaken.
    @ObservationIgnored private(set) var lastCommandServerMs: Double = 0

    @ObservationIgnored private var displayName: String?
    /// The host token, or this member's token from the welcome. Memory only: never logged, never saved.
    @ObservationIgnored private var secret: String?
    @ObservationIgnored private var socket: PartySocket?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pings: Task<Void, Never>?
    @ObservationIgnored private var clock = PartyClock()
    @ObservationIgnored private var lastRev = -1
    @ObservationIgnored private var lastSuggestAt: Double = -100
    @ObservationIgnored private var lastRequestAt: Double = -100

    private enum Outcome {
        case ended(String)
        case quota
        case dropped
    }

    private init() {}

    var isHost: Bool { role == "host" }

    /// Server time now, in ms, from the clock estimate.
    func serverNow() -> Double { PartyTime.unixMs + clock.offset }

    // MARK: Entering and leaving

    /// Starts a party with this device as host. The code comes back in `code`.
    func createRoom(hostName: String) async {
        guard phase == .idle else { return }
        guard let name = PartyName.clean(hostName) else {
            notice = "Enter a name first."
            return
        }
        phase = .connecting
        do {
            let room = try await PartyAPI().createRoom(hostName: name)
            code = room.code
            role = "host"
            memberId = room.memberId
            secret = room.hostToken
            displayName = name
            startConnection()
        } catch {
            fail(error)
        }
    }

    /// Joins a party as a guest. The room's state arrives on the socket once the welcome does.
    func join(code rawCode: String, name rawName: String) async {
        guard phase == .idle else { return }
        guard let code = PartyCode.clean(rawCode), let name = PartyName.clean(rawName) else {
            notice = "Enter a six-letter code and a name."
            return
        }
        phase = .connecting
        do {
            let info = try await PartyAPI().roomInfo(code: code)
            if info.full {
                phase = .ended(reason: "full")
                notice = PartyText.full
                return
            }
            if info.locked {
                phase = .ended(reason: "locked")
                notice = PartyText.locked
                return
            }
        } catch CloudError.rejected(let status, _, _) where status == 404 {
            phase = .idle
            notice = PartyText.noRoom
            return
        } catch {
            fail(error)
            return
        }
        self.code = code
        role = "guest"
        memberId = nil
        secret = nil
        displayName = name
        startConnection()
    }

    /// Guest: leaves the party. Host: ends it for everyone (the same as `end()`).
    func leave() {
        if isHost {
            end()
            return
        }
        guard code != nil else { return }
        loop?.cancel()
        loop = nil
        let socket = self.socket
        self.socket = nil
        pings?.cancel()
        pings = nil
        Task {
            _ = try? await socket?.send(PartyOutgoing.make("leave"))
            socket?.close()
        }
        listener?.partyRoomEnded()
        resetRoom()
        phase = .idle
        notice = nil
    }

    /// Host: ends the party for everyone. The server's `closed` answer then ends it here too.
    func end() {
        guard isHost else { return }
        send("end")
    }

    /// Forgets the room on this device, for example after it ended or was unavailable. Tells the server nothing.
    func dismiss() {
        loop?.cancel()
        loop = nil
        teardownSocket()
        if code != nil { listener?.partyRoomEnded() }
        resetRoom()
        phase = .idle
        notice = nil
    }

    /// Call when the app comes back to the foreground: reconnects now instead of waiting out the backoff.
    func reconnectNow() {
        guard code != nil, phase == .reconnecting else { return }
        startConnection()
    }

    // MARK: Connection

    private func startConnection() {
        loop?.cancel()
        teardownSocket()
        clock = PartyClock()
        lastRev = -1
        loop = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.connectionLoop()
        }
    }

    /// Connects, and when the connection drops, waits and connects again. Ends on a server verdict or a quota.
    private func connectionLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            switch await connectOnce() {
            case .ended(let reason):
                if Task.isCancelled { return }
                finishRoom(reason: reason)
                return
            case .quota:
                if Task.isCancelled { return }
                teardownSocket()
                phase = .unavailable(message: PartyText.quota)
                return
            case .dropped:
                if Task.isCancelled { return }
                attempt += 1
                phase = .reconnecting
                try? await Task.sleep(for: .seconds(PartyBackoff.seconds(forAttempt: attempt)))
            }
        }
    }

    /// One socket, from hello until it closes.
    private func connectOnce() async -> Outcome {
        guard let code, let name = displayName, let url = PartyAPI().socketURL(code: code) else {
            return .ended("gone")
        }
        let socket = PartySocket()
        self.socket = socket
        var hello: [String: Any] = ["name": name]
        if let memberId, let secret {
            hello["memberId"] = memberId
            hello["token"] = secret
        }
        let events = socket.open(url)
        _ = try? await socket.send(PartyOutgoing.make("hello", hello))

        var outcome = Outcome.dropped
        reading: for await event in events {
            switch event {
            case .message(let message):
                if let ending = handle(message) {
                    outcome = ending
                    break reading
                }
            case .closed(let status):
                outcome = Self.outcome(afterClose: status)
                break reading
            }
        }
        if self.socket === socket { teardownSocket() }
        return outcome
    }

    private static func outcome(afterClose status: Int?) -> Outcome {
        guard let status else { return .dropped }
        if status == 503 { return .quota }
        if (400..<500).contains(status), status != 429 { return .ended("gone") }
        return .dropped
    }

    /// Applies one server message. Returns an outcome when the message ends the connection.
    private func handle(_ message: PartyServerMessage) -> Outcome? {
        switch message {
        case .welcome(let id, let token, let role, let snapshot):
            memberId = id
            if let token { secret = token }
            self.role = role
            apply(snapshot)
            phase = .inRoom
            notice = nil
            startPings()
        case .state(let next):
            accept(next)
        case .members(let list):
            members = list
        case .suggestion(let suggestion):
            suggestions.removeAll { $0.id == suggestion.id }
            suggestions.insert(suggestion, at: 0)
            if suggestions.count > 10 { suggestions.removeLast(suggestions.count - 10) }
        case .request(let request):
            guard isHost, !requests.contains(where: { $0.id == request.id }) else { break }
            requests.append(request)
            let id = request.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.requests.removeAll { $0.id == id }
            }
        case .resolved(let id, _):
            requests.removeAll { $0.id == id }
        case .error(_, let text):
            notice = text.isEmpty ? nil : text
        case .closed(let reason):
            return .ended(reason)
        case .pong(let sent, let server):
            clock.addPong(sentAt: sent, serverAt: server, receivedAt: PartyTime.unixMs)
        case .other:
            break
        }
        return nil
    }

    private func apply(_ snapshot: PartySnapshot) {
        members = snapshot.members
        suggestions = Array(snapshot.suggestions.prefix(10))
        autoApprove = snapshot.autoApprove
        locked = snapshot.locked
        lastRev = -1
        if let snapshotState = snapshot.state {
            accept(snapshotState)
        } else {
            state = nil
        }
    }

    /// Keeps a state only if it is newer than the one held (by `rev`), then tells the listener.
    private func accept(_ next: PartyState) {
        guard next.rev > lastRev else { return }
        lastRev = next.rev
        state = next
        listener?.partyStateChanged(next)
    }

    private func startPings() {
        pings?.cancel()
        pings = Task { @MainActor [weak self] in
            guard let self else { return }
            // Three quick pings to get the clock right, then one every 30 seconds.
            for _ in 0..<3 {
                self.sendPing()
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            while true {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                self.sendPing()
            }
        }
    }

    private func sendPing() {
        send("ping", ["c": PartyTime.unixMs])
    }

    private func teardownSocket() {
        pings?.cancel()
        pings = nil
        socket?.close()
        socket = nil
    }

    private func finishRoom(reason: String) {
        teardownSocket()
        phase = .ended(reason: reason)
        notice = isHost && reason == "ended" ? "You ended the party." : PartyText.reason(reason)
        listener?.partyRoomEnded()
    }

    private func fail(_ error: Error) {
        if case CloudError.quota = error {
            phase = .unavailable(message: PartyText.quota)
        } else {
            phase = .unavailable(message: PartyText.unreachable)
        }
    }

    private func resetRoom() {
        code = nil
        role = nil
        memberId = nil
        secret = nil
        displayName = nil
        members = []
        state = nil
        suggestions = []
        requests = []
        autoApprove = false
        locked = false
        lastRev = -1
    }

    // MARK: Sending

    /// Sends one message on the open socket. Commands (anything but a ping) also stamp `lastCommandServerMs`.
    private func send(_ type: String, _ fields: [String: Any] = [:]) {
        guard let socket else { return }
        if type != "ping" { lastCommandServerMs = serverNow() }
        let data = PartyOutgoing.make(type, fields)
        Task { _ = try? await socket.send(data) }
    }

    private func hostSend(_ type: String, _ fields: [String: Any] = [:]) {
        guard isHost else { return }
        send(type, fields)
    }

    // MARK: Host commands. The host's player says what the room's playback is.

    /// Starts a title for the room. Guests then resolve it on their own devices.
    func load(_ source: PartySource, at position: Double? = nil) {
        var fields: [String: Any] = ["source": source.wireObject]
        if let position { fields["pos"] = PartyPosition.clamp(position) }
        hostSend("load", fields)
    }

    func play(at position: Double) {
        hostSend("play", ["pos": PartyPosition.clamp(position)])
    }

    func pause(at position: Double) {
        hostSend("pause", ["pos": PartyPosition.clamp(position)])
    }

    func seek(to position: Double) {
        hostSend("seek", ["pos": PartyPosition.clamp(position)])
    }

    /// Every 15 seconds while playing, so the room's clock does not drift.
    func sync(at position: Double) {
        hostSend("sync", ["pos": PartyPosition.clamp(position)])
    }

    func rate(_ value: Double) {
        hostSend("rate", ["rate": value])
    }

    /// Approves or denies a guest request. The adapter applies an approval to the host's own player.
    func resolve(_ request: PartyRequest, approve: Bool) {
        requests.removeAll { $0.id == request.id }
        hostSend("resolve", ["id": request.id, "approve": approve])
    }

    func kick(_ member: PartyMember) {
        guard member.id != memberId else { return }
        hostSend("kick", ["memberId": member.id])
    }

    /// Locks or unlocks the room. The contract has no broadcast for this, so the host's copy is set here at once.
    func setLocked(_ on: Bool) {
        guard isHost else { return }
        locked = on
        hostSend("lock", ["locked": on])
    }

    /// Auto-approve applies guest requests at once. Like `setLocked`, the host's copy is set here at once.
    func setAutoApprove(_ on: Bool) {
        guard isHost else { return }
        autoApprove = on
        hostSend("autoApprove", ["on": on])
    }

    // MARK: Guest commands

    /// Suggests a title to the room. One per 10 seconds; returns false when it was not sent.
    @discardableResult
    func suggest(_ source: PartySource, note: String? = nil) -> Bool {
        guard !isHost, code != nil, PartyTime.monotonic - lastSuggestAt >= 10 else { return false }
        lastSuggestAt = PartyTime.monotonic
        var fields: [String: Any] = ["source": source.wireObject]
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            fields["note"] = String(note.prefix(200))
        }
        send("suggest", fields)
        return true
    }

    /// Asks the host to start playing. One request at a time; it lapses after 30 seconds.
    func askHostToPlay() { askHost("play") }

    /// Asks the host to pause.
    func askHostToPause() { askHost("pause") }

    private func askHost(_ action: String) {
        guard !isHost, code != nil, PartyTime.monotonic - lastRequestAt >= 30 else { return }
        lastRequestAt = PartyTime.monotonic
        send("request", ["action": action])
    }

    /// Guest: whether this device has a source for the room's title and can play it.
    func setReady(_ ready: Bool) {
        guard !isHost, code != nil else { return }
        send("ready", ["ready": ready])
    }
}
