import Foundation

// The pure rules of Pear.pair sync: keys, fingerprints, reading this device's data, and how a pulled record merges into the
// local lists. Port of SyncRecords.kt. Nothing here touches the network or the timers. Fingerprints are compared only on this
// device, so they need not match the Kotlin ones; the data sent on the wire must.

extension Date {
    /// Unix milliseconds, the time the API uses.
    var unixMs: Double { timeIntervalSince1970 * 1000 }
}

/// Keys of records in the snapshot: profile, kind and key, joined by U+0001, which no id contains.
@MainActor
enum RecordKey {
    static let sep = "\u{1}"

    static func make(_ profile: String, _ kind: SyncKind, _ key: String) -> String {
        [profile, kind.rawValue, key].joined(separator: sep)
    }

    static func parse(_ composite: String) -> (profile: String, kind: SyncKind, key: String)? {
        let parts = composite.components(separatedBy: sep)
        guard parts.count == 3, let kind = SyncKind(rawValue: parts[1]) else { return nil }
        return (parts[0], kind, parts[2])
    }

    /// The token of one title's progress, used by the cadence rules.
    static func token(_ profile: String, _ title: String) -> String { profile + sep + title }

    static func inScope(_ composite: String, _ scope: SyncScope) -> Bool {
        guard let parts = parse(composite), parts.kind == scope.kind else { return false }
        return scope.profile.isEmpty || parts.profile == scope.profile
    }
}

@MainActor
enum Fingerprint {
    /// Sorted-key JSON of an object: equal objects give equal strings.
    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A history record without its playback fields: a change to what the title is, not to where it was stopped.
    static func history(_ object: [String: Any]) -> String {
        json(object.filter { !SyncRules.playbackFields.contains($0.key) })
    }
}

@MainActor
enum SyncJSON {
    /// The JSON object a value encodes to, as the wire carries it.
    static func object<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// Decodes a record's data. Nil when it is not the shape the type expects.
    static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Reads and writes this device's synced data. The keys are the ones the stores use, so nothing about the storage changes.
@MainActor
enum LocalStore {
    static var defaultProfile: Profile { Profile(id: Profile.defaultID, name: "Me", colorHex: Theme.defaultHex) }

    /// The profile list as stored. Without one, the device has the default profile, as ProfileStore shows it.
    static func profiles() -> (list: [Profile], complete: Bool) {
        guard let data = UserDefaults.standard.data(forKey: ProfileKeys.list) else { return ([defaultProfile], true) }
        guard let list = try? JSONDecoder().decode([Profile].self, from: data) else { return ([], false) }
        return list.isEmpty ? ([defaultProfile], true) : (list, true)
    }

    /// A stored array of records. `complete` is false when the stored value could not be read.
    static func read<T: Decodable>(_ key: String, _ type: T.Type) -> (items: [T], complete: Bool) {
        guard let data = UserDefaults.standard.data(forKey: key) else { return ([], true) }
        guard let items = try? JSONDecoder().decode([T].self, from: data) else { return ([], false) }
        return (items, true)
    }

    static func write<T: Encodable>(_ key: String, _ items: [T]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func history(_ profile: String) -> (live: [WatchHistory.Entry], archive: [WatchHistory.Entry], complete: Bool) {
        let live = read(ProfileKeys.scoped("watch.history", profile), WatchHistory.Entry.self)
        let archive = read(ProfileKeys.scoped("watch.archive", profile), WatchHistory.Entry.self)
        return (live.items, archive.items, live.complete && archive.complete)
    }

    static func writeHistory(_ profile: String, _ lists: HistoryLists) {
        write(ProfileKeys.scoped("watch.history", profile), lists.live)
        write(ProfileKeys.scoped("watch.archive", profile), lists.archive)
    }

    /// Live and archived entries as one list. A title in both counts once, from the live list.
    static func liveFirst(_ live: [WatchHistory.Entry], _ archive: [WatchHistory.Entry]) -> [WatchHistory.Entry] {
        var seen = Set<String>()
        var out: [WatchHistory.Entry] = []
        for entry in live + archive where seen.insert(entry.id).inserted {
            out.append(entry)
        }
        return out
    }

    /// The profile list's records. The list is one global scope, keyed by profile id.
    static func profileRecords() -> LocalSet {
        let stored = profiles()
        var records: [String: LocalRecord] = [:]
        for profile in stored.list {
            let body = SyncJSON.object(profile)
            records[RecordKey.make(profile.id, .profile, profile.id)] = LocalRecord(
                profile: profile.id, kind: .profile, key: profile.id, intrinsicAt: nil,
                body: body, fingerprint: Fingerprint.json(body))
        }
        return LocalSet(records: records, complete: stored.complete)
    }

    static func historyRecords(_ profile: String) -> LocalSet {
        let stored = history(profile)
        var records: [String: LocalRecord] = [:]
        for entry in liveFirst(stored.live, stored.archive) {
            let body = SyncJSON.object(entry)
            records[RecordKey.make(profile, .history, entry.id)] = LocalRecord(
                profile: profile, kind: .history, key: entry.id, intrinsicAt: entry.updated.unixMs,
                body: body, fingerprint: Fingerprint.history(body))
        }
        return LocalSet(records: records, complete: stored.complete)
    }

    /// Progress for a title that has a saveable position. Nothing is synced before the length is known.
    static func progressRecords(_ profile: String) -> LocalSet {
        let stored = history(profile)
        var records: [String: LocalRecord] = [:]
        for entry in liveFirst(stored.live, stored.archive) {
            guard let progress = progress(of: entry) else { continue }
            let body = SyncJSON.object(progress)
            records[RecordKey.make(profile, .progress, entry.id)] = LocalRecord(
                profile: profile, kind: .progress, key: entry.id, intrinsicAt: entry.updated.unixMs,
                body: body, fingerprint: Fingerprint.json(body))
        }
        return LocalSet(records: records, complete: stored.complete)
    }

    static func progress(of entry: WatchHistory.Entry) -> ProgressData? {
        guard entry.position.isFinite, entry.duration.isFinite, entry.position > 0, entry.duration > 0 else { return nil }
        return ProgressData(position: entry.position, duration: entry.duration, season: entry.season, episode: entry.episode)
    }

    static func libraryRecords(_ profile: String) -> LocalSet {
        let stored = read(ProfileKeys.scoped("library.local", profile), LocalLibrary.Entry.self)
        var records: [String: LocalRecord] = [:]
        for entry in stored.items {
            let body = SyncJSON.object(entry)
            records[RecordKey.make(profile, .library, entry.item.id)] = LocalRecord(
                profile: profile, kind: .library, key: entry.item.id, intrinsicAt: entry.added.unixMs,
                body: body, fingerprint: Fingerprint.json(body))
        }
        return LocalSet(records: records, complete: stored.complete)
    }

    /// One profile's watch log as stored, by day. `complete` is false when the stored value cannot be read.
    static func watchLog(_ profile: String) -> (days: [String: [Int]], complete: Bool) {
        guard let data = UserDefaults.standard.data(forKey: ProfileKeys.scoped("watch.log", profile)) else { return ([:], true) }
        guard let days = try? JSONDecoder().decode([String: [Int]].self, from: data) else { return ([:], false) }
        return (days, true)
    }

    /// The watch log as records, one per month (`yyyy-MM`). Incomplete on purpose: a month missing here is not a delete,
    /// so no tombstone is ever sent for it (as in Kotlin).
    static func watchLogRecords(_ profile: String) -> LocalSet {
        var byMonth: [String: [String: [Int]]] = [:]
        for (day, hours) in watchLog(profile).days {
            byMonth[String(day.prefix(7)), default: [:]][day] = hours
        }
        var records: [String: LocalRecord] = [:]
        for (month, days) in byMonth {
            let body = watchLogBody(days)
            records[RecordKey.make(profile, .watchlog, month)] = LocalRecord(
                profile: profile, kind: .watchlog, key: month, intrinsicAt: nil,
                body: body, fingerprint: Fingerprint.json(body))
        }
        return LocalSet(records: records, complete: false)
    }

    /// One month's record body: `{"d": {day: [24 whole numbers]}}`. Its fingerprint is the sorted JSON, so equal days give
    /// equal fingerprints on every device.
    static func watchLogBody(_ days: [String: [Int]]) -> [String: Any] {
        ["d": days]
    }

    /// Reads one pulled month. A day is kept when its key is a date and its 24 values are whole numbers from 0 to
    /// `SyncRules.maxHourSeconds`. Any other day is left out, and only that day. Nil when the record has no `d` object.
    static func decodeWatchLogMonth(_ data: [String: Any]) -> [String: [Int]]? {
        guard let days = data["d"] as? [String: Any] else { return nil }
        var out: [String: [Int]] = [:]
        for (day, value) in days {
            guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  let values = value as? [Any], values.count == 24 else { continue }
            let hours: [Int] = values.compactMap { (element: Any) -> Int? in
                guard let number = element as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let hour = Int(exactly: number.doubleValue),
                      (0...SyncRules.maxHourSeconds).contains(hour) else { return nil }
                return hour
            }
            if hours.count == 24 { out[day] = hours }
        }
        return out
    }

    /// Two logs as one: for each day, the larger count of each hour, with a day missing on one side counting as zeros. The
    /// result does not depend on the order of `a` and `b`, and merging a log with itself changes nothing.
    static func mergeWatchLogs(_ a: [String: [Int]], _ b: [String: [Int]]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for day in Set(a.keys).union(b.keys) {
            let x = a[day] ?? []
            let y = b[day] ?? []
            out[day] = (0..<24).map { hour in max(hourValue(x, hour), hourValue(y, hour)) }
        }
        return trimWatchLog(out)
    }

    private static func hourValue(_ hours: [Int], _ hour: Int) -> Int {
        hour < hours.count ? hours[hour] : 0
    }

    /// Keeps the newest 400 days once a log holds more than 430. A smaller log comes back as it is (as WatchLog.flush does).
    static func trimWatchLog(_ days: [String: [Int]]) -> [String: [Int]] {
        guard days.count > 430 else { return days }
        let keep = Set(days.keys.sorted().suffix(400))
        return days.filter { keep.contains($0.key) }
    }

    /// Whether the profile's library is synced over Pear.pair: the rule of Kotlin's `syncsLibraryOverPair`. A library the
    /// person kept on "This device" is left out, and a Pear.pair library is synced. Before any choice, or on Simkl, it is
    /// synced only while Simkl is not connected. Read from storage, because the profile may not be the loaded one.
    static func syncsLibrary(profile: String, simklConnected: Bool) -> Bool {
        // The choice is read as text, so a value this build does not know never fails the whole read.
        struct Choice: Decodable { let choice: String? }
        let stored = UserDefaults.standard.data(forKey: ProfileKeys.scoped("library.prefs", profile))
            .flatMap { try? JSONDecoder().decode(Choice.self, from: $0) }
        switch (stored?.choice) ?? "" {
        case "local": return false
        case "pair": return true
        default: return !simklConnected
        }
    }
}

/// How pulled records merge into the local data (cloud/CLOUD_API.md §2.2, client rules).
@MainActor
enum Merge {
    static func later(_ a: (season: Int, episode: Int), than b: (season: Int, episode: Int)) -> Bool {
        a.season != b.season ? a.season > b.season : a.episode > b.episode
    }

    /// The watched marker both sides agree on: the larger one. The newer side can clear it on purpose (wS == 0), and then the
    /// clear wins. Progress on another device never lowers a marker, because progress carries no marker at all.
    static func watched(local: WatchHistory.Entry?, remote: WatchHistory.Entry) -> (season: Int?, episode: Int?) {
        guard let local else { return (remote.wS, remote.wE) }
        let newer = local.updated > remote.updated ? local : remote
        if newer.wS == 0 { return (0, 0) }
        let a = local.watchedThrough
        let b = remote.watchedThrough
        var best: (season: Int, episode: Int)? = a ?? b
        if let a, let b { best = later(a, than: b) ? a : b }
        guard let best else { return (nil, nil) }
        return (best.season, best.episode)
    }

    /// The entry that wins on everything else (the newer one), with the merged watched marker.
    static func history(local: WatchHistory.Entry?, remote: WatchHistory.Entry) -> WatchHistory.Entry {
        let marker = watched(local: local, remote: remote)
        var out = remote
        if let local, local.updated > remote.updated { out = local }
        out.wS = marker.season
        out.wE = marker.episode
        return out
    }

    /// A title belongs in the live list when it is in progress, or a series with a watched marker (Up Next needs it there).
    static func belongsLive(_ entry: WatchHistory.Entry) -> Bool {
        entry.isInProgress || (entry.item.type == "series" && entry.watchedThrough != nil)
    }

    /// A pulled library record replaces the one with the same title id.
    static func upsertLibrary(_ list: inout [LocalLibrary.Entry], _ remote: LocalLibrary.Entry) {
        list.removeAll { $0.item.id == remote.item.id }
        list.append(remote)
    }

    /// A pulled profile replaces the one with the same id, or is added when there is room (the local limit is ProfileStore.limit).
    static func upsertProfile(_ list: inout [Profile], _ remote: Profile) -> Bool {
        if let i = list.firstIndex(where: { $0.id == remote.id }) {
            list[i] = remote
            return true
        }
        if list.count >= ProfileStore.limit { return false }
        list.append(remote)
        return true
    }
}

/// The live and archive lists of one profile's history, kept the way WatchHistory keeps them.
@MainActor
struct HistoryLists {
    var live: [WatchHistory.Entry]
    var archive: [WatchHistory.Entry]

    /// Takes `remote` as the title's record, merged with what is here.
    mutating func upsert(_ remote: WatchHistory.Entry) {
        let local = (live + archive).first { $0.id == remote.id }
        let merged = Merge.history(local: local, remote: remote)
        remove(remote.id)
        place(merged)
    }

    mutating func remove(_ id: String) {
        live.removeAll { $0.id == id }
        archive.removeAll { $0.id == id }
    }

    /// Playback progress from another device, for a title already here. Only a newer record is applied, and only the
    /// position, length and episode move; the watched marker stays. Returns false when nothing was applied.
    mutating func applyProgress(_ titleID: String, _ progress: ProgressData, updatedAt: Double) -> Bool {
        guard let local = (live + archive).first(where: { $0.id == titleID }) else { return false }
        if updatedAt <= local.updated.unixMs { return false }
        var moved = local
        moved.position = progress.position
        moved.duration = progress.duration
        moved.updated = Date(timeIntervalSince1970: updatedAt / 1000)
        moved.season = progress.season ?? local.season
        moved.episode = progress.episode ?? local.episode
        if let season = progress.season, let episode = progress.episode {
            moved.key = "\(season):\(episode)"
        }
        remove(titleID)
        place(moved)
        return true
    }

    /// Newest first, at most the live cap. The rest go to the archive, except the ones that must stay live.
    mutating func settle() {
        live.sort { $0.updated > $1.updated }
        while live.count > SyncRules.historyLiveCap {
            guard let i = live.lastIndex(where: { !$0.isInProgress && !($0.item.type == "series" && $0.watchedThrough != nil) }) else {
                break
            }
            archive.append(live.remove(at: i))
        }
    }

    private mutating func place(_ entry: WatchHistory.Entry) {
        if Merge.belongsLive(entry) {
            live.append(entry)
        } else {
            archive.append(entry)
        }
    }
}
