import Foundation
import Observation

// Batch S2, watch party logic. Not compiled: the owner's CI builds it.

/// Follows the room on this device. It opens the room's source through the viewer's own add-ons (`loadSource`, set by the
/// room UI), then keeps the player on the room's clock. Play and pause follow the room. Small drift is corrected with a
/// speed nudge (the same `engine.setRate` the speed slider uses), and large drift with a seek. The viewer's own speed
/// setting is never changed here, only the engine's speed while the room is playing.
@MainActor @Observable
final class PartyGuestAdapter: PartyRoomListener {
    enum SourceStatus: Equatable, Sendable {
        case waitingForHost
        case resolving
        case playing
        /// Nothing resolved on this device. The room keeps going; the viewer can retry or pick a source by hand.
        case unavailable
    }

    private(set) var sourceStatus: SourceStatus = .waitingForHost

    /// Opens `source` on this device at `position` (seconds) through the viewer's own add-ons and starts the player there.
    /// Returns false when nothing resolves here. The room UI (batch S3) sets this. While it is nil, nothing resolves.
    @ObservationIgnored var loadSource: ((PartySource, Double) async -> Bool)?

    @ObservationIgnored private let session: PartySession
    @ObservationIgnored private let model: PlayerModel
    @ObservationIgnored private var attached = false
    /// True while a load or a seek is running, so two passes never overlap.
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var latest: PartyState?
    @ObservationIgnored private var loaded: PartySource?
    @ObservationIgnored private var failed: PartySource?
    @ObservationIgnored private var drift = DriftController()
    @ObservationIgnored private var lastPlaying = false
    /// The engine speed this adapter last set. Nil means "set it again on the next pass" (after a play, a seek or a load).
    @ObservationIgnored private var lastPushedRate: Double?
    @ObservationIgnored private var lastToggleAt: Double = -100
    @ObservationIgnored private var lastAutoSeekAt: Double = -100
    @ObservationIgnored private var bufferingSince: Double?
    @ObservationIgnored private var reportedReady: Bool?
    @ObservationIgnored private var tick: Task<Void, Never>?

    init(model: PlayerModel) {
        self.model = model
        self.session = PartySession.shared
    }

    /// The player's position in seconds: the engine's clock while it runs, else the seek bar's copy.
    private var position: Double {
        model.engine.map { Double($0.clock.currentTime) } ?? model.playhead.position
    }

    // MARK: Attach

    /// Starts following the room on this player. Call when the player opens as a guest.
    func attach() {
        guard !attached else { return }
        attached = true
        loaded = nil
        failed = nil
        sourceStatus = .waitingForHost
        latest = session.state
        reportedReady = nil
        bufferingSince = nil
        session.listener = self
        startTick()
    }

    /// Stops following the room. The player goes back to the viewer's own speed.
    func detach() {
        guard attached else { return }
        attached = false
        tick?.cancel()
        tick = nil
        if session.listener === self { session.listener = nil }
        setEngineRate(model.rate)
    }

    /// The viewer asks for the room's source again, after "No source on your device".
    func retrySource() {
        failed = nil
        sourceStatus = .waitingForHost
        Task { await reconcile() }
    }

    // MARK: PartyRoomListener

    func partyStateChanged(_ state: PartyState) {
        latest = state
        Task { await reconcile() }
    }

    func partyRoomEnded() {
        detach()
    }

    // MARK: Pass

    /// Once per second, and on every state: loads the room's source when it changes, then lines the player up with the room.
    private func startTick() {
        tick?.cancel()
        tick = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                self.reportReady()
                await self.reconcile()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func reconcile() async {
        guard attached, !busy, let state = latest else { return }
        busy = true
        defer { busy = false }

        if let wanted = state.source, wanted != loaded {
            guard wanted != failed else { return }
            sourceStatus = .resolving
            var ok = false
            if let loader = loadSource {
                ok = await loader(wanted, PartyPosition.target(for: state, serverNow: session.serverNow()))
            }
            guard attached else { return }
            guard ok else {
                failed = wanted
                sourceStatus = .unavailable
                return
            }
            loaded = wanted
            failed = nil
            sourceStatus = .playing
            lastPlaying = model.isPlaying
            lastPushedRate = nil
        }

        guard let current = latest, let onScreen = loaded, current.source == onScreen else {
            if latest?.source == nil, loaded == nil { sourceStatus = .waitingForHost }
            return
        }
        await align(to: current)
    }

    /// Plays or pauses to match the room, then corrects the position.
    private func align(to state: PartyState) async {
        guard !model.isBuffering, !model.didEnd else { return }
        let now = PartyTime.monotonic
        let wantPlaying = state.playing

        if model.isPlaying != wantPlaying {
            // Give the engine a second to act before asking again, so a toggle is never sent twice.
            if now - lastToggleAt > 1 {
                lastToggleAt = now
                model.togglePlay()
            }
            return
        }
        if model.isPlaying && !lastPlaying { lastPushedRate = nil }
        lastPlaying = model.isPlaying

        let target = PartyPosition.target(for: state, serverNow: session.serverNow())
        let action = drift.step(drift: position - target, playing: wantPlaying, baseRate: state.rate, now: now)
        switch action {
        case .hold:
            if wantPlaying, lastPushedRate != state.rate { setEngineRate(state.rate) }
        case .rate(let rate):
            setEngineRate(rate)
        case .seek:
            guard now - lastAutoSeekAt >= 3 else { return }
            lastAutoSeekAt = now
            await model.seek(to: target)
            lastPushedRate = nil
        }
    }

    /// Reports "ready" to the room: false while the player has been stalled for 1.5 seconds, or has no source; true otherwise.
    private func reportReady() {
        let now = PartyTime.monotonic
        if model.isBuffering {
            bufferingSince = bufferingSince ?? now
        } else {
            bufferingSince = nil
        }
        let stalled = bufferingSince.map { now - $0 >= 1.5 } ?? false
        let ready = loaded != nil && !stalled
        if reportedReady != ready {
            reportedReady = ready
            session.setReady(ready)
        }
    }

    /// Sets the engine's speed while it is playing. The viewer's own speed setting is left alone.
    private func setEngineRate(_ rate: Double) {
        guard model.isPlaying, let engine = model.engine else { return }
        Self.push(engine.setRate, rate)
        lastPushedRate = rate
    }

    private static func push<T: BinaryFloatingPoint>(_ set: (T) -> Void, _ value: Double) {
        set(T(value))
    }
}
