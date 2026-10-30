import Foundation
import Observation
import UIKit

/// Another device on the account that is playing a title right now, or has paused it a moment ago.
struct LivePresence: Identifiable, Equatable {
    let deviceID: String
    let deviceName: String
    let profileID: String?
    let item: MetaPreview
    let key: String
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let thumb: String?
    /// Where that device was at `asOfMs`.
    let position: Double
    let duration: Double
    let paused: Bool
    /// Unix ms on this device's clock at which `position` was true.
    let asOfMs: Double

    var id: String { deviceID }

    /// Where that device is by now: a playing one has moved on since its last beat, a paused one has not.
    func position(at now: Date) -> Double {
        guard !paused else { return position }
        let ahead = max(0, now.unixMs - asOfMs) / 1000
        return duration > 0 ? min(position + ahead, duration) : position + ahead
    }

    /// Reads one device of the presence answer. Nil when it is stopped, or lacks what a card needs (the title and its place).
    /// `offsetMs` is the server's clock minus this device's, `fetchedAtMs` this device's clock when the answer arrived.
    @MainActor
    static func parse(_ d: [String: Any], offsetMs: Double, fetchedAtMs: Double) -> LivePresence? {
        guard let deviceID = (d["deviceId"] as? String) ?? (d["device"] as? String),
              let itemObject = d["item"] as? [String: Any],
              let item = SyncJSON.decode(MetaPreview.self, itemObject) else { return nil }
        let state = (d["state"] as? String) ?? "playing"
        if state == "stopped" { return nil }
        guard let position = (d["position"] as? NSNumber)?.doubleValue, position.isFinite, position >= 0 else { return nil }
        let duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
        let at = ((d["at"] ?? d["updatedAt"] ?? d["ts"]) as? NSNumber)?.doubleValue
        let name = [d["deviceName"], d["name"], d["platform"]].compactMap { $0 as? String }.first { !$0.isEmpty }
        let key = (d["key"] as? String) ?? ""
        return LivePresence(
            deviceID: deviceID,
            deviceName: name ?? "another device",
            profileID: d["profileId"] as? String,
            item: item,
            key: key,
            season: (d["season"] as? NSNumber)?.intValue,
            episode: (d["episode"] as? NSNumber)?.intValue,
            episodeTitle: d["episodeTitle"] as? String,
            thumb: d["thumb"] as? String,
            position: position,
            duration: duration.isFinite ? duration : 0,
            paused: state == "paused",
            asOfMs: at.map { $0 - offsetMs } ?? fetchedAtMs)
    }
}

/// "Currently watching" (cloud/CLOUD_API.md §2.3). Sends what this device is playing, and reads what the others are playing.
///
/// Presence lives only in memory on the server (never in D1): a playing device beats every 15 seconds, at once on a pause or
/// when it goes to the background, and says `stopped` when it leaves the player. An entry fades 45 seconds after its last beat
/// while playing, 5 minutes while paused. Every beat has a `seq` that only grows on this device, so the server drops a beat that
/// arrives after a newer one, and a late `stopped` for one episode can never erase the next. Beats go out one at a time, in order.
@MainActor @Observable
final class PresenceService {
    static let shared = PresenceService()

    /// The other devices of this profile that are playing now, newest beat first.
    private(set) var others: [LivePresence] = []
    @ObservationIgnored private var fetchedAt: Date?
    /// True from a playing beat until a pause or a stop. A device that is playing does not look for others.
    @ObservationIgnored private var playingHere = false
    @ObservationIgnored private var lastSeq: Double = 0
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var lastSent: (profile: String, titleID: String, season: Int?, episode: Int?)?
    @ObservationIgnored private let client = PairClient()
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    // MARK: Sending (the player)

    /// This device is playing (or has paused) a title. The caller has made sure `position` is real: past the point the file
    /// opened at, with the length known.
    func beat(item: MetaPreview, key: String, season: Int?, episode: Int?, episodeTitle: String?, thumb: String?,
              position: Double, duration: Double, paused: Bool) {
        guard let bearer = PairSync.shared.bearer, position.isFinite, duration.isFinite, duration > 0 else { return }
        let profile = ProfileKeys.activeID
        var body: [String: Any] = [
            "profileId": profile,
            "state": paused ? "paused" : "playing",
            "seq": nextSeq(),
            "titleId": item.id,
            "item": SyncJSON.object(item),
            "key": key,
            "position": position,
            "duration": duration,
        ]
        if let season { body["season"] = season }
        if let episode { body["episode"] = episode }
        if let episodeTitle { body["episodeTitle"] = episodeTitle }
        if let thumb { body["thumb"] = thumb }
        playingHere = !paused
        lastSent = (profile, item.id, season, episode)
        enqueue(bearer: bearer, body: body)
    }

    /// This device left the player. Does nothing when no beat went out for the title.
    func stop() {
        playingHere = false
        guard let sent = lastSent, let bearer = PairSync.shared.bearer else { lastSent = nil; return }
        lastSent = nil
        var body: [String: Any] = [
            "profileId": sent.profile,
            "state": "stopped",
            "seq": nextSeq(),
            "titleId": sent.titleID,
        ]
        if let season = sent.season { body["season"] = season }
        if let episode = sent.episode { body["episode"] = episode }
        enqueue(bearer: bearer, body: body)
    }

    /// A number that is larger than every one this device sent before.
    private func nextSeq() -> Double {
        lastSeq = max(lastSeq + 1, Date().unixMs)
        return lastSeq
    }

    /// Sends after the one before it has finished, so the server sees the beats in the order they were made. A failed beat is
    /// not retried: the next one is 15 seconds away and carries newer data.
    private func enqueue(bearer: String, body: [String: Any]) {
        beginBackgroundTime()
        let previous = inFlight
        let client = client
        inFlight = Task { [weak self] in
            await previous?.value
            try? await client.sendPresence(bearer: bearer, beat: body)
            self?.endBackgroundTime()
        }
    }

    /// A beat sent as the app leaves the screen gets time to finish.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pear.pair.presence") { [weak self] in
            self?.endBackgroundTime()
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Reading (Home, the player)

    /// Looks for the other devices now and then every 20 seconds, until the task is cancelled. Home runs it while it is on
    /// screen and the app is in front.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(SyncRules.presencePollSeconds))
        }
    }

    /// Reads the presence of the account once. Does nothing while this device is playing, or without an account.
    func refresh() async {
        guard let bearer = PairSync.shared.bearer, let me = PairSync.shared.deviceID else {
            if !others.isEmpty { others = [] }
            return
        }
        guard !playingHere else { return }
        guard let answer = try? await client.presence(bearer: bearer) else { return }
        let profile = ProfileKeys.activeID
        let offset = PairSync.shared.clockOffsetMs
        let now = Date()
        let list = answer.compactMap { LivePresence.parse($0, offsetMs: offset, fetchedAtMs: now.unixMs) }
            .filter { $0.deviceID != me && ($0.profileID == nil || $0.profileID == profile) }
            .sorted { $0.asOfMs > $1.asOfMs }
        fetchedAt = now
        if list != others { others = list }
    }

    /// Where another device is in this episode right now, when one is playing it (or paused on it a moment ago) and the
    /// last look is recent. The player opens there instead of at the saved position, which can lag by up to a minute.
    func livePosition(titleID: String, season: Int?, episode: Int?) -> Double? {
        guard let fetchedAt, Date().timeIntervalSince(fetchedAt) < 60 else { return nil }
        guard let live = others.first(where: { $0.item.id == titleID && $0.season == season && $0.episode == episode }) else { return nil }
        let position = live.position(at: Date())
        guard live.duration <= 0 || position < live.duration * 0.92 else { return nil }
        return position
    }
}
