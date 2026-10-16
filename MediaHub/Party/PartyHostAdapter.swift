import Foundation
import Observation

// Batch S2, watch party logic. Not compiled: the owner's CI builds it.

/// Seeks and speed changes that the player reports. The host's play and pause are read from the player itself.
@MainActor
protocol PlayerTransportObserver: AnyObject {
    func playerDidSeek(to position: Double)
    func playerDidSetRate(_ rate: Double)
}

/// Drives the room from the host's player. Whatever the host does with the player (its own controls, the remote, the lock
/// screen) goes to the room: play and pause from the player's state, seeks and speed through `PlayerTransportObserver`.
/// A change the room makes on its own (a guest request under auto-approve) is applied to the player. The host never applies
/// an echo of its own command: an echo older than the host's latest command is ignored.
@MainActor
final class PartyHostAdapter: PartyRoomListener, PlayerTransportObserver {
    private let session: PartySession
    private let model: PlayerModel
    private var attached = false
    private var source: PartySource?
    /// Play or pause as the room was last told. A change made in the player is sent once, and a change the room made is not
    /// sent back.
    private var lastPlaying = false
    private var lastToggleAt: Double = -100
    private var syncTask: Task<Void, Never>?
    private var rateTask: Task<Void, Never>?

    init(model: PlayerModel) {
        self.model = model
        self.session = PartySession.shared
    }

    /// The player's position in seconds: the engine's clock while it runs, else the seek bar's copy.
    private var position: Double {
        model.engine.map { Double($0.clock.currentTime) } ?? model.playhead.position
    }

    // MARK: Attach

    /// Starts driving the room from this player. Call when the player opens as host.
    func attach() {
        guard !attached else { return }
        attached = true
        lastPlaying = model.isPlaying
        model.transportObserver = self
        session.listener = self
        observePlayback()
        if lastPlaying { startSync() }
    }

    /// Stops driving the room from this player. The room itself is untouched.
    func detach() {
        guard attached else { return }
        attached = false
        model.transportObserver = nil
        if session.listener === self { session.listener = nil }
        stopSync()
        rateTask?.cancel()
        rateTask = nil
    }

    /// Call when the host closes the player without ending the party: the room pauses, and the party stays open.
    func leavePlayer() {
        if lastPlaying {
            lastPlaying = false
            session.pause(at: position)
        }
        detach()
    }

    /// Call when the host starts a title. The room gets the title; the player's own play event starts it there.
    func loadSource(from request: PlayRequest, resumeAt: Double? = nil) {
        let described = PartySource(request: request)
        source = described
        lastPlaying = false
        session.load(described, at: resumeAt)
    }

    /// Approves or denies a guest's request. An approval also takes effect on this player.
    func decide(_ request: PartyRequest, approve: Bool) {
        session.resolve(request, approve: approve)
        guard approve, !model.isBuffering else { return }
        let playing = request.action == "play"
        if playing != model.isPlaying { setLocalPlaying(playing) }
    }

    // MARK: Play and pause from the player

    /// Watches the player's play state. Re-arms itself after every change.
    private func observePlayback() {
        guard attached else { return }
        _ = withObservationTracking {
            _ = model.isPlaying
            _ = model.isBuffering
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.playbackChanged()
                self.observePlayback()
            }
        }
    }

    private func playbackChanged() {
        guard attached else { return }
        if model.isBuffering {
            // A new title resets the player to paused while it loads. The room hears about the play when it starts.
            if !model.isPlaying { lastPlaying = false }
            return
        }
        let playing = model.isPlaying
        guard playing != lastPlaying else { return }
        lastPlaying = playing
        if playing {
            session.play(at: position)
            startSync()
        } else {
            session.pause(at: position)
            stopSync()
        }
    }

    /// Plays or pauses the player because the room asked (or an approval did). Marks it as already told, so it isn't sent back.
    private func setLocalPlaying(_ playing: Bool) {
        lastPlaying = playing
        lastToggleAt = PartyTime.monotonic
        model.togglePlay()
        if playing { startSync() } else { stopSync() }
    }

    // MARK: PlayerTransportObserver

    func playerDidSeek(to position: Double) {
        guard attached else { return }
        session.seek(to: position)
    }

    /// Speed changes come in while a slider is dragged, so only the last value is sent.
    func playerDidSetRate(_ rate: Double) {
        guard attached else { return }
        rateTask?.cancel()
        rateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.session.rate(self.model.rate)
        }
    }

    // MARK: Sync heartbeat

    /// Every 15 seconds while playing, the room gets the host's position.
    private func startSync() {
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                if self.model.isPlaying { self.session.sync(at: self.position) }
            }
        }
    }

    private func stopSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    // MARK: PartyRoomListener

    /// A state the room made on its own: a guest request that auto-approve applied. Echoes of this host's commands are older
    /// than its latest command, so they are dropped here.
    func partyStateChanged(_ state: PartyState) {
        guard attached else { return }
        guard state.at >= session.lastCommandServerMs else { return }
        guard !model.isBuffering, state.playing != model.isPlaying else { return }
        guard PartyTime.monotonic - lastToggleAt > 1.5 else { return }
        setLocalPlaying(state.playing)
    }

    func partyRoomEnded() {
        stopSync()
        rateTask?.cancel()
        rateTask = nil
    }
}
