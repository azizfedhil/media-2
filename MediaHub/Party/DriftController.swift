import Foundation

// Batch S2, watch party logic. Not compiled: the owner's CI builds it.

/// Where the room is now, in seconds.
enum PartyPosition {
    static let maxSeconds: Double = 86_400

    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), maxSeconds) : 0
    }

    /// The position the room has at `serverNow` (Unix ms): the stored position, moved on while playing.
    static func target(for state: PartyState, serverNow: Double) -> Double {
        var position = state.pos
        if state.playing {
            position += max(0, serverNow - state.at) / 1000 * state.rate
        }
        return clamp(position)
    }
}

/// What the guest's player should do about the gap to the room.
enum DriftAction: Equatable {
    /// Close enough, or nothing to change.
    case hold
    /// Play at this speed: the room's speed, or the room's speed nudged by 4% to close a gap.
    case rate(Double)
    /// Jump to the room's position.
    case seek
}

/// The drift rules from plan section 5, as a pure decision with no timers and no player. Under 0.4 s: hold. 0.4 s to 2 s:
/// nudge the speed by 4% until close again. Over 2 s: seek. If a nudge has not closed the gap after 8 s, the engine is not
/// taking the speed change here, so seek instead.
struct DriftController {
    static let closeEnough: Double = 0.4
    static let seekAbove: Double = 2.0
    static let nudge: Double = 0.04
    static let nudgeWindow: Double = 8
    static let minimumProgress: Double = 0.1

    private(set) var nudging = false
    private var windowStart: Double = 0
    private var windowDrift: Double = 0

    /// `drift` is the player's position minus the room's (positive means ahead). `now` is a monotonic clock in seconds.
    mutating func step(drift: Double, playing: Bool, baseRate: Double, now: Double) -> DriftAction {
        let size = abs(drift)
        guard playing else {
            nudging = false
            return size >= Self.closeEnough ? .seek : .hold
        }
        if size > Self.seekAbove {
            nudging = false
            return .seek
        }
        if size < Self.closeEnough {
            guard nudging else { return .hold }
            nudging = false
            return .rate(baseRate)
        }
        if !nudging {
            nudging = true
            windowStart = now
            windowDrift = size
        } else if now - windowStart >= Self.nudgeWindow {
            if windowDrift - size < Self.minimumProgress {
                nudging = false
                return .seek
            }
            windowStart = now
            windowDrift = size
        }
        // Ahead of the room: slow down. Behind it: speed up.
        return .rate(baseRate + (drift > 0 ? -Self.nudge : Self.nudge))
    }
}
