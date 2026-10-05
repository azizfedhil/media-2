import Foundation
import Observation

/// Local progress for the active profile. Powers Continue Watching, resume, and "Because you watched…" suggestions.
/// (Simkl sync will mirror this later.)
@MainActor @Observable
final class WatchHistory {
    struct Entry: Codable, Identifiable {
        let item: MetaPreview
        var key: String            // stream id incl. episode, so resume only applies to the same episode
        var position: Double
        var duration: Double
        var updated: Date
        // Added later; optional so history saved by older builds still decodes.
        var season: Int? = nil
        var episode: Int? = nil
        var episodeTitle: String? = nil
        var thumb: String? = nil   // episode still, or the movie backdrop
        var id: String { item.id }

        var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
        /// Watched far enough that the next episode is the natural thing to offer.
        var isFinished: Bool { duration > 0 && position >= duration * 0.92 }
        /// Season/episode, from the stored fields or (older entries) parsed from the "2:5" key.
        var seasonEpisode: (season: Int, episode: Int)? {
            if let s = season, let e = episode { return (s, e) }
            let p = key.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        /// Eligible for "Up Next": a finished series episode whose numbers we can read.
        var isUpNextCandidate: Bool { isFinished && item.type == "series" && seasonEpisode != nil }
    }
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var profileID = ProfileKeys.activeID
    private var storeKey: String { ProfileKeys.scoped("watch.history", profileID) }

    init() { entries = Self.read(storeKey) }

    /// Switches to another profile's history. No-op when it is already loaded.
    func load(profile id: String) {
        guard id != profileID else { return }
        profileID = id
        entries = Self.read(storeKey)
    }

    private static func read(_ key: String) -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return e
    }

    var lastWatched: MetaPreview? { entries.first?.item }
    var continueEntries: [Entry] {
        entries.filter { $0.position > 30 && !$0.isFinished }
    }
    /// Ids of the shows whose last episode is done — cheap to diff, so views use them as `.task(id:)` keys.
    var finishedSeries: Set<String> { Set(entries.compactMap { $0.isUpNextCandidate ? $0.id : nil }) }
    /// Shows whose last episode is done: candidates for "Up Next".
    var finishedEntries: [Entry] {
        entries.filter { $0.isUpNextCandidate }
    }
    var continueWatching: [MetaPreview] { continueEntries.map(\.item) }
    func entry(for id: String) -> Entry? { entries.first { $0.id == id } }

    func update(_ item: MetaPreview, key: String, position: Double, duration: Double,
                season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, thumb: String? = nil) {
        entries.removeAll { $0.id == item.id }
        entries.insert(Entry(item: item, key: key, position: position, duration: duration, updated: .now,
                             season: season, episode: episode, episodeTitle: episodeTitle, thumb: thumb), at: 0)
        entries = Array(entries.prefix(30))
        persist()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    // MARK: Mark as watched (used by long-press menus on posters, seasons and episodes)

    /// Marks a whole title watched at once: an entry whose position sits at its end.
    /// `duration` is the expected runtime in seconds (episode stills, season totals); when unknown,
    /// the existing entry's duration is kept so Up Next can still resolve the following episode.
    func markWatched(_ item: MetaPreview, key: String = "watched", season: Int? = nil, episode: Int? = nil,
                     duration: Double? = nil, episodeTitle: String? = nil, thumb: String? = nil) {
        let old = entry(for: item.id)
        let d = max(duration ?? 0, old.map { $0.isFinished ? $0.duration : 0 } ?? 0, 60)
        update(item, key: key, position: d, duration: d,
               season: season ?? old?.season, episode: episode ?? old?.episode,
               episodeTitle: episodeTitle ?? old?.episodeTitle, thumb: thumb ?? old?.thumb)
    }

    /// Clears the watched flag without dropping the rest of the record.
    func unmarkWatched(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].isFinished else { return }
        entries[i].position = min(entries[i].position, entries[i].duration * 0.5)
        persist()
    }

    /// Everything up to and including `season`/`episode` counts as watched afterwards.
    func isWatched(id: String? = nil, season s: Int, episode e: Int) -> Bool {
        let target = id ?? lastWatchedSeriesID ?? ""
        guard let en = entry(for: target), en.isFinished, let se = en.seasonEpisode else { return false }
        return (se.season, se.episode) >= (s, e)
    }

    /// The show the caller most recently resolved ids for — used only as a hint; callers pass explicit ids where possible.
    @ObservationIgnored var lastWatchedSeriesID: String?

    /// Marks Sx·Ey finished for `item`, extending the run backwards to cover every earlier episode too.
    func markThrough(episode ep: Int, season s: Int, item: MetaPreview, duration: Double?,
                     episodeTitle: String? = nil, thumb: String? = nil) {
        let old = entry(for: item.id)
        let coversEarlier = old?.isFinished == true && old?.seasonEpisode.map({ ($0.season, $0.episode) >= (s, ep) }) == true
        let d = max(duration ?? 0, old?.duration ?? 0, 60)
        if coversEarlier, let se = old?.seasonEpisode {
            update(item, key: "\(se.season):\(se.episode)", position: se.episode == ep && se.season == s ? d : d,
                   duration: d, season: se.season, episode: se.episode,
                   episodeTitle: episodeTitle ?? old?.episodeTitle, thumb: thumb ?? old?.thumb)
            return
        }
        update(item, key: "\(s):\(ep)", position: d, duration: d, season: s, episode: ep,
               episodeTitle: episodeTitle, thumb: thumb)
    }

    /// Pulls the watched marker back to just before Sx·Ey, so that episode (and everything after it) is unwatched.
    func unmarkThrough(episode ep: Int, season s: Int, item: MetaPreview) {
        guard let i = entries.firstIndex(where: { $0.id == item.id }), entries[i].isFinished,
              let se = entries[i].seasonEpisode, (se.season, se.episode) >= (s, ep) else { return }
        let prev: (season: Int, episode: Int)?
        if ep > 1 { prev = (s, ep - 1) } else if s > 1 { prev = (s - 1, 99) } else { prev = nil }
        if let p = prev {
            entries[i].key = "\(p.season):\(p.episode)"
            entries[i].season = p.season
            entries[i].episode = p.episode
        } else {
            entries.remove(at: i)
        }
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: storeKey) }
    }
}

/// Time formatting shared by the player and the Continue Watching cards.
enum Fmt {
    /// 83 -> "1:23", 3725 -> "1:02:05"
    static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// 2460 -> "41 min left", 4500 -> "1h 15m left"
    static func remaining(_ s: Double) -> String {
        let m = max(Int((max(s, 0) / 60).rounded(.up)), 1)
        if m >= 60 { return m % 60 == 0 ? "\(m / 60)h left" : "\(m / 60)h \(m % 60)m left" }
        return "\(m) min left"
    }
}
