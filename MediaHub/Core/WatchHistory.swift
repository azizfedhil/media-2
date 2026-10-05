import Foundation
import Observation

/// Local progress for the active profile. Powers Continue Watching, resume, and "Because you watched…".
/// (Simkl sync will mirror this later.)
///
/// Two things are stored per title and they are deliberately **separate**:
/// * **Playback progress** — one `Entry` per title: where you stopped in the episode you actually played.
///   It drives Continue Watching and resume only, never watched state.
/// * **Watched state** — the explicit `watchedEpisodes` / `finishedSeries` sets of `"S:E"` keys.
///   Manual marks/unmarks touch only the exact episodes named; playback completion marks only the
///   episode that was played. Nothing is inferred from "how far into the show" a marker sits, so
///   marking one episode or season can no longer cascade onto other episodes or seasons.
@MainActor @Observable
final class WatchHistory {
    struct Entry: Codable, Identifiable {
        let item: MetaPreview
        var key: String            // stream id incl. episode, so resume only applies to the same episode
        var position: Double       // seconds into THIS entry's episode
        var duration: Double       // seconds of THIS entry's episode (never a season/show total)
        var updated: Date
        // Added later; optional so history saved by older builds still decodes.
        var season: Int? = nil
        var episode: Int? = nil
        var episodeTitle: String? = nil
        var thumb: String? = nil   // episode still, or the movie backdrop
        var id: String { item.id }

        var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
        /// Playback ran far enough that the next episode is the natural thing to offer.
        /// Pure playback progress: watched state lives in `watchedEpisodes` / `finishedSeries`.
        var isFinished: Bool { duration >= 60 && position >= duration * 0.92 }
        /// Season/episode, from the stored fields or (older entries) parsed from the "2:5" key.
        /// Impossible pairs (e.g. S8 E96 written by legacy code) yield nil instead of leaking through.
        var seasonEpisode: (season: Int, episode: Int)? {
            if let s = season, let e = episode, Self.isPlausible(season: s, episode: e) { return (s, e) }
            let p = key.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 && Self.isPlausible(season: p[0], episode: p[1]) ? (p[0], p[1]) : nil
        }

        /// Bounds used everywhere an S/E pair enters or leaves storage. Real shows never reach these
        /// ceilings; anything outside them is fabricated data and must not be trusted.
        static func isPlausible(season s: Int, episode e: Int) -> Bool { (1...40).contains(s) && (1...600).contains(e) }
        static func isPlausible(season s: Int?, episode e: Int?) -> Bool {
            guard let s, let e else { return true }
            return isPlausible(season: s, episode: e)
        }
        /// A resume point must belong to the episode it names: an impossible S/E pair, a non-finite
        /// time, or a position past the end of the episode is dropped rather than shown or resumed.
        var isValidProgress: Bool {
            position.isFinite && duration.isFinite && duration >= 60 && duration <= 86_400
                && position >= 0 && position <= duration * 1.05
                && Self.isPlausible(season: season, episode: episode)
        }
    }

    /// Explicitly marked-watched episodes, keyed by title id → set of `"S:E"` strings.
    /// Independent from `entries`: playing an episode to the end does not write here implicitly via
    /// any marker comparison, and marking here never moves or creates a progress record.
    private(set) var watchedEpisodes: [String: Set<String>] = [:]
    /// Titles whose whole run was explicitly marked watched (the show-level action; always movies).
    private(set) var finishedSeries: Set<String> = []

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var profileID = ProfileKeys.activeID
    private var storeKey: String { ProfileKeys.scoped("watch.history", profileID) }
    private var watchedStoreKey: String { ProfileKeys.scoped("watch.watched", profileID) }

    init() {
        entries = Self.read(storeKey)
        watchedEpisodes = Self.readWatched(watchedStoreKey)
    }

    /// Switches to another profile's history. No-op when it is already loaded.
    func load(profile id: String) {
        guard id != profileID else { return }
        profileID = id
        entries = Self.read(storeKey)
        watchedEpisodes = Self.readWatched(watchedStoreKey)
    }

    private static func read(_ key: String) -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        // Legacy histories contain synthetic markers written by the old prefix-based watched system:
        // fabricated durations (whole-season totals → "48:00:00") and invented episodes ("S8 E96").
        // They are sanitized on load so they can neither appear in Continue Watching nor imply watched state.
        return sanitize(e)
    }

    private static func sanitize(_ list: [Entry]) -> [Entry] {
        var out: [Entry] = []
        var seen: Set<String> = []
        for var en in list {
            guard !seen.contains(en.id) else { continue }   // one progress record per title
            seen.insert(en.id)
            if !en.isValidProgress {
                // The old "mark watched" wrote position == duration == a fabricated value. Such
                // records carry no real resume data: drop them entirely. Entries with merely a
                // slightly off position get clamped instead of discarded.
                let looksSynthetic = en.duration > 0 && abs(en.position - en.duration) < 0.001
                if looksSynthetic { continue }
                if !en.duration.isFinite || !(60...86_400).contains(en.duration) { continue }
                en.position = min(max(en.position.isFinite ? en.position : 0, 0), en.duration)
            }
            if !entryIsPlausible(&en) { continue }
            out.append(en)
        }
        return Array(out.prefix(30))
    }

    /// Drops impossible season/episode fields (keeping the entry itself; `seasonEpisode` then falls
    /// back to parsing the key) and rejects entries whose key claims an impossible episode.
    private static func entryIsPlausible(_ en: inout Entry) -> Bool {
        if let s = en.season, let e = en.episode, !Entry.isPlausible(season: s, episode: e) {
            en.season = nil; en.episode = nil
        }
        let p = en.key.split(separator: ":").compactMap { Int($0) }
        if p.count == 2, !Entry.isPlausible(season: p[0], episode: p[1]) { return false }
        return true
    }

    private static func readWatched(_ key: String) -> [String: Set<String>] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let w = try? JSONDecoder().decode([String: [String]].self, from: d) else { return [:] }
        // Migration/sanitization: keep only well-formed "S:E" keys inside plausible bounds.
        var out: [String: Set<String>] = [:]
        for (id, list) in w {
            let valid = Set(list.filter { parseSE($0) != nil })
            if !valid.isEmpty { out[id] = valid }
        }
        return out
    }

    /// Parses an "S:E" watched key; nil for anything malformed or out of plausible range.
    private static func parseSE(_ k: String) -> (season: Int, episode: Int)? {
        let p = k.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, Entry.isPlausible(season: p[0], episode: p[1]) else { return nil }
        return (p[0], p[1])
    }

    private static func seKey(_ s: Int, _ e: Int) -> String { "\(s):\(e)" }

    var lastWatched: MetaPreview? { entries.first?.item }
    /// Unfinished playback positions worth resuming, newest first. Movies disappear once played
    /// through; series stay listed even after an episode ends (so "keep watching" still finds them).
    var continueEntries: [Entry] {
        entries.filter { $0.isValidProgress }
               .filter { $0.position > 30 && $0.position < $0.duration * 0.92 }
               .filter { $0.item.type != "movie" || !$0.isFinished }
    }
    /// Progress records of shows with a known episode: candidates for "Up Next". Whether that episode
    /// counts as done is decided by the watched sets (`isWatched`) plus playback completion, so a
    /// half-played episode never offers "next".
    var seriesProgress: [Entry] {
        entries.filter { $0.item.type == "series" && $0.seasonEpisode != nil }
    }
    var continueWatching: [MetaPreview] { continueEntries.map(\.item) }
    func entry(for id: String) -> Entry? { entries.first { $0.id == id } }

    // MARK: Playback progress (Continue Watching / resume)

    /// Records where playback stopped. Marks the episode watched when it was actually played through —
    /// and only the episode identified by `season`/`episode`, never anything around it.
    func update(_ item: MetaPreview, key: String, position: Double, duration: Double,
                season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, thumb: String? = nil) {
        guard duration.isFinite, duration >= 60, duration <= 86_400,
              position.isFinite, position >= 0,
              Entry.isPlausible(season: season, episode: episode) else { return }
        let pos = min(position, duration)
        let old = entry(for: item.id)
        let oldSE = old?.seasonEpisode
        // Never let a new source claim a shorter runtime than the same episode already has on record:
        // a mismatched duration would make a mid-episode position look like completion.
        let dur: Double
        if let old, oldSE?.season == season, oldSE?.episode == episode,
           old.duration >= duration, old.duration <= duration * 2 {
            dur = max(old.duration, duration)
        } else {
            dur = duration
        }
        entries.removeAll { $0.id == item.id }
        entries.insert(Entry(item: item, key: key, position: pos, duration: dur, updated: .now,
                             season: season, episode: episode, episodeTitle: episodeTitle, thumb: thumb), at: 0)
        entries = Array(entries.prefix(30))
        persist()
        // Completion of the episode that was actually played. Movies finish the title itself.
        if pos >= dur * 0.92 {
            if item.type == "series", let s = season, let e = episode {
                setEpisodeWatched(item.id, season: s, episode: e, watched: true)
            } else if item.type != "series" {
                setSeriesWatched(item.id, watched: true)
            }
        }
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    // MARK: Manual watched actions

    /// Marks exactly one episode watched (or unwatched). Touches nothing else — no neighbours,
    /// no earlier/later episodes, no other seasons, and no progress records.
    func setEpisodeWatched(_ id: String, season s: Int, episode e: Int, watched: Bool) {
        guard Entry.isPlausible(season: s, episode: e) else { return }
        if watched {
            watchedEpisodes[id, default: []].insert(Self.seKey(s, e))
        } else if var set = watchedEpisodes[id] {
            set.remove(Self.seKey(s, e))
            if set.isEmpty { watchedEpisodes[id] = nil } else { watchedEpisodes[id] = set }
        }
        persistWatched()
    }

    /// Marks every listed episode of one season watched/unwatched — and only those. The caller supplies
    /// the actual episode numbers (from TMDB/the loaded list); nothing outside the list is touched.
    func setSeasonWatched(_ id: String, season s: Int, episodes: [Int], watched: Bool) {
        guard Entry.isPlausible(season: s, episode: 1), !episodes.isEmpty else { return }
        var set = watchedEpisodes[id] ?? []
        for e in episodes where Entry.isPlausible(season: s, episode: e) {
            if watched { set.insert(Self.seKey(s, e)) } else { set.remove(Self.seKey(s, e)) }
        }
        if set.isEmpty { watchedEpisodes[id] = nil } else { watchedEpisodes[id] = set }
        persistWatched()
    }

    /// Whole-title watched flag (movies always, series via the show-level action).
    func setSeriesWatched(_ id: String, watched: Bool) {
        if watched { finishedSeries.insert(id) } else { finishedSeries.remove(id) }
        persistWatched()
    }

    /// "Mark Episodes Until Here": the listed episodes of the season up to `upToEpisode`, plus the
    /// single following one (so Up Next keeps pointing ahead). Only ever touches the given season.
    func setThroughWatched(_ id: String, season s: Int, listedEpisodes: [Int], upToEpisode e: Int, watched: Bool) {
        guard Entry.isPlausible(season: s, episode: e) else { return }
        let sorted = listedEpisodes.sorted()
        let eps = sorted.isEmpty ? Array(1...max(min(e, 600), 1)) : sorted.filter { $0 <= e }
        setSeasonWatched(id, season: s, episodes: eps, watched: watched)
        if watched {
            let next = sorted.first { $0 > e } ?? (eps.isEmpty ? nil : e + 1)
            if let n = next, Entry.isPlausible(season: s, episode: n) {
                setEpisodeWatched(id, season: s, episode: n, watched: true)
            }
        }
    }

    /// True when the whole show was explicitly marked watched.
    func isSeriesWatched(_ id: String) -> Bool { finishedSeries.contains(id) }

    /// Watched state of one episode. Exact membership only — never a prefix comparison against a
    /// "furthest watched" marker, which is what used to cascade watched flags across seasons.
    func isWatched(id: String, season s: Int, episode e: Int) -> Bool {
        finishedSeries.contains(id) || watchedEpisodes[id]?.contains(Self.seKey(s, e)) == true
    }

    /// Count of watched episodes in one season; `.max` when the whole show is marked.
    func watchedCount(inSeason id: String, season s: Int) -> Int {
        if finishedSeries.contains(id) { return .max }
        return watchedEpisodes[id]?.filter { Self.parseSE($0)?.season == s }.count ?? 0
    }

    /// Clears all watched flags for a title (episodes + whole-show). Progress is left alone.
    func clearWatched(_ id: String) {
        watchedEpisodes[id] = nil
        finishedSeries.remove(id)
        persistWatched()
    }

    // MARK: Legacy shims (no call sites remain; kept so old code paths can never resurrect the bug)

    /// Old API: previously wrote a fabricated progress marker. Now only sets the whole-show flag —
    /// playback data is never invented here, and per-episode marking must use `setEpisodeWatched`.
    func markWatched(_ item: MetaPreview, key: String = "watched", season: Int? = nil, episode: Int? = nil,
                     duration: Double? = nil, episodeTitle: String? = nil, thumb: String? = nil) {
        setSeriesWatched(item.id, watched: true)
    }

    /// Clears the watched flags without dropping the rest of the record.
    func unmarkWatched(_ id: String) {
        clearWatched(id)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    private func persistWatched() {
        let encodable = watchedEpisodes.compactMapValues { $0.isEmpty ? nil : Array($0).sorted() }
        if let d = try? JSONEncoder().encode(encodable) { UserDefaults.standard.set(d, forKey: watchedStoreKey) }
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
