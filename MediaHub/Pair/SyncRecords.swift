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

    /// Whether the profile's library is Simkl: the rule of LibraryPrefs.usesSimkl. A connected Simkl is the library unless
    /// the profile chose Local. Read from storage, because the profile may not be the loaded one.
    static func usesSimkl(profile: String, connected: Bool) -> Bool {
        guard connected else { return false }
        struct Choice: Decodable { let choice: LibrarySource? }
        guard let data = UserDefaults.standard.data(forKey: ProfileKeys.scoped("library.prefs", profile)),
              let stored = try? JSONDecoder().decode(Choice.self, from: data) else { return true }
        return (stored.choice ?? .simkl) == .simkl
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
