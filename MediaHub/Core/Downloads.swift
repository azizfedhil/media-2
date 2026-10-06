import Foundation
import Observation

// MARK: - Model

struct DownloadRecord: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, downloading, failed, done }

    /// "<imdb>|movie" or "<imdb>|<season>:<episode>"
    let id: String
    let item: MetaPreview
    let imdb: String
    let season: Int?
    let episode: Int?
    var episodeTitle: String?
    var thumb: URL?
    var logo: URL?
    var runtime: Int?
    /// Which add-on / release this came from (later episodes of a season reuse it).
    var sourceAddonID: String?
    var sourceSignature: String?
    /// Nil until resolved: season downloads resolve each episode right before it starts, so links never go stale in the queue.
    var remoteURL: URL?
    var headers: [String: String] = [:]
    /// File name inside the Downloads folder (never an absolute path: the app container path can change).
    var fileName: String?
    var bytes: Int64 = 0
    var expectedBytes: Int64 = 0
    var progress: Double = 0
    var state: State = .queued
    var error: String?
    var added: Date = .now

    var isEpisode: Bool { season != nil }

    static func key(imdb: String, season: Int?, episode: Int?) -> String {
        guard let season, let episode else { return "\(imdb)|movie" }
        return "\(imdb)|\(season):\(episode)"
    }

    /// Ready-to-play request for the offline file. Same key format as online playback, so watch history stays consistent.
    func playRequest() -> PlayRequest? {
        guard state == .done, let f = fileName else { return nil }
        return PlayRequest(url: DownloadFiles.url(for: f), headers: [:], item: item,
                           key: isEpisode ? "\(season ?? 0):\(episode ?? 0)" : "movie", imdb: imdb,
                           season: season, episode: episode, episodeTitle: episodeTitle,
                           logo: logo, thumb: thumb ?? item.backdropURL,
                           sourceAddonID: sourceAddonID, sourceSignature: sourceSignature, p2p: nil)
    }
}

// MARK: - HTTPS-only gate

extension StreamItem {
    /// Only plain HTTPS add-on links can be saved. Torrents (P2P) never can, and HLS playlists aren't a single file.
    var downloadURL: URL? {
        guard let s = url, let u = URL(string: s), u.scheme?.lowercased() == "https",
              u.pathExtension.lowercased() != "m3u8" else { return nil }
        return u
    }
    var isDownloadable: Bool { downloadURL != nil }
}

// MARK: - Files

enum DownloadFiles {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }
    static var index: URL { directory.appendingPathComponent("index.json") }
    static func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    /// Free space the system would let us use (includes purgeable space).
    static var freeBytes: Int64? {
        try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Source resolving (HTTPS only)

enum DownloadResolver {
    /// Preferred add-on + release (same source as the rest of the season), then the pinned source, then the first
    /// HTTPS stream from any add-on. Never returns a torrent.
    @MainActor
    static func resolve(imdb: String, type: String, season: Int?, episode: Int?,
                        preferAddonID: String?, preferSignature: String?,
                        addons: [Addon], pins: PinnedSources?) async -> (addon: Addon, stream: StreamItem, url: URL)? {
        let sid = (season != nil && episode != nil) ? "\(imdb):\(season!):\(episode!)" : imdb
        let groups = await AddonClient.shared.streams(for: sid, type: type, addons: addons)
        let ordered = addons.compactMap { a in groups.first(where: { $0.0.id == a.id }) }

        func match(_ addonID: String, _ signature: String?) -> (Addon, StreamItem, URL)? {
            guard let g = ordered.first(where: { $0.0.id == addonID }) else { return nil }
            let ok = g.1.filter(\.isDownloadable)
            guard let s = ok.first(where: { $0.signature == signature }) ?? ok.first, let u = s.downloadURL else { return nil }
            return (g.0, s, u)
        }

        if let a = preferAddonID, let r = match(a, preferSignature) { return r }
        if let pin = pins?.pin(for: imdb), let r = match(pin.addonID, pin.signature) { return r }
        for g in ordered { if let s = g.1.first(where: \.isDownloadable), let u = s.downloadURL { return (g.0, s, u) } }
        return nil
    }
}

// MARK: - Manager

@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var records: [DownloadRecord] = []
    /// Set by the app delegate when iOS relaunches us for finished background transfers.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var store: AddonStore?
    @ObservationIgnored private var pins: PinnedSources?
    @ObservationIgnored private var pumping = false

    private init() {
        DownloadFiles.prepare()
        records = Self.loadIndex()
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.example.MediaHub.downloads")
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: cfg, delegate: SessionDelegate(), delegateQueue: nil)
        reconcile()
    }

    func configure(store: AddonStore, pins: PinnedSources) {
        self.store = store; self.pins = pins
        pump()
    }

    // MARK: Lookup

    func record(imdb: String, season: Int?, episode: Int?) -> DownloadRecord? {
        let id = DownloadRecord.key(imdb: imdb, season: season, episode: episode)
        return records.first { $0.id == id }
    }

    func isDownloaded(imdb: String, season: Int?, episode: Int?) -> Bool {
        record(imdb: imdb, season: season, episode: episode)?.state == .done
    }

    /// Bytes on disk (finished files plus what in-progress ones have written so far).
    var usedBytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
    var hasActive: Bool { records.contains { $0.state == .queued || $0.state == .downloading } }

    func records(imdb: String, season: Int? = nil) -> [DownloadRecord] {
        records.filter { $0.imdb == imdb && (season == nil || $0.season == season) }
    }

    // MARK: Adding

    /// Queues one title/episode. With a `stream` (picked in the sources sheet) it must be HTTPS; without one, the
    /// source is resolved automatically when its turn comes. Returns false when the stream can't be downloaded.
    @discardableResult
    func enqueue(item: MetaPreview, imdb: String, season: Int?, episode: Int?, episodeTitle: String?,
                 thumb: URL?, logo: URL?, runtime: Int?, addonID: String? = nil, stream: StreamItem? = nil) -> Bool {
        var url: URL?
        if let stream {
            guard let u = stream.downloadURL else { return false }   // torrents and non-HTTPS never download
            url = u
        }
        let id = DownloadRecord.key(imdb: imdb, season: season, episode: episode)
        if let i = records.firstIndex(where: { $0.id == id }) {
            guard records[i].state == .failed else { return true }  // already queued / downloading / done
            discardFile(records[i])
            records.remove(at: i)
        }
        records.append(DownloadRecord(id: id, item: item, imdb: imdb, season: season, episode: episode,
                                      episodeTitle: episodeTitle, thumb: thumb, logo: logo, runtime: runtime,
                                      sourceAddonID: stream == nil ? nil : addonID,
                                      sourceSignature: stream?.signature,
                                      remoteURL: url, headers: stream?.requestHeaders ?? [:]))
        save(); pump()
        return true
    }

    /// Queues every aired episode of a season, in order. They download one at a time, episode by episode.
    func enqueueSeason(item: MetaPreview, imdb: String, season: Int, episodes: [EpisodeItem], logo: URL?) {
        let today = Self.isoDay.string(from: .now)
        for ep in episodes {
            if let d = ep.airDate, !d.isEmpty, d > today { continue }   // not aired yet
            enqueue(item: item, imdb: imdb, season: season, episode: ep.id, episodeTitle: ep.name,
                    thumb: ep.image ?? item.backdropURL, logo: logo, runtime: ep.runtime)
        }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    func retry(_ id: String) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].state == .failed else { return }
        records[i].state = .queued; records[i].error = nil; records[i].progress = 0; records[i].bytes = 0
        save(); pump()
    }

    /// Called when the connection comes back: queued items were waiting for it.
    func networkReturned() { pump() }

    // MARK: Deleting (also cancels anything still in flight)

    func delete(_ id: String) { remove { $0.id == id } }
    func delete(imdb: String, season: Int) { remove { $0.imdb == imdb && $0.season == season } }
    func delete(imdb: String) { remove { $0.imdb == imdb } }
    func deleteAll() { remove { _ in true } }

    private func remove(where match: (DownloadRecord) -> Bool) {
        let gone = records.filter(match)
        guard !gone.isEmpty else { return }
        let names = Set(gone.compactMap(\.fileName))
        records.removeAll(where: match)
        for r in gone { discardFile(r) }
        session.getAllTasks { tasks in
            tasks.filter { names.contains($0.taskDescription ?? "") }.forEach { $0.cancel() }
        }
        save(); pump()
    }

    private func discardFile(_ r: DownloadRecord) {
        if let f = r.fileName { try? FileManager.default.removeItem(at: DownloadFiles.url(for: f)) }
    }

    // MARK: Queue (one transfer at a time)

    private func pump() {
        guard !pumping, Connectivity.shared.isOnline != false, store != nil,
              !records.contains(where: { $0.state == .downloading }),
              let next = records.first(where: { $0.state == .queued }) else { return }
        pumping = true
        let id = next.id
        Task {
            await start(id)
            pumping = false
            pump()      // moves on if that one failed; returns immediately while one is downloading
        }
    }

    private func start(_ id: String) async {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        var r = records[i]
        var ext = "mp4"

        if r.remoteURL == nil {
            // Same source as the rest of this season when there is one.
            let sibling = records.first { $0.imdb == r.imdb && $0.season == r.season && $0.sourceAddonID != nil && $0.id != r.id }
            guard let found = await DownloadResolver.resolve(
                imdb: r.imdb, type: r.item.type, season: r.season, episode: r.episode,
                preferAddonID: r.sourceAddonID ?? sibling?.sourceAddonID,
                preferSignature: r.sourceSignature ?? sibling?.sourceSignature,
                addons: store?.addons ?? [], pins: pins) else {
                fail(id, "No HTTPS source found"); return
            }
            r.remoteURL = found.url
            r.headers = found.stream.requestHeaders
            r.sourceAddonID = found.addon.id
            r.sourceSignature = found.stream.signature
            let e = found.stream.fileExtension
            if !e.isEmpty { ext = e }
        } else if let u = r.remoteURL {
            let e = u.pathExtension.lowercased()
            if !e.isEmpty { ext = e }
        }
        ext = String(ext.filter { $0.isLetter || $0.isNumber }.prefix(4))
        if ext.isEmpty { ext = "mp4" }

        // The record may have been deleted while the source was being resolved.
        guard let j = records.firstIndex(where: { $0.id == id }), let url = r.remoteURL else { return }
        r.fileName = "\(UUID().uuidString.lowercased()).\(ext)"
        r.state = .downloading; r.error = nil; r.progress = 0; r.bytes = 0
        records[j] = r
        save()

        var req = URLRequest(url: url)
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = session.downloadTask(with: req)
        task.taskDescription = r.fileName
        task.resume()
    }

    // MARK: Session callbacks (hopped onto the main actor by SessionDelegate)

    fileprivate func progress(_ name: String, written: Int64, expected: Int64) {
        guard let i = records.firstIndex(where: { $0.fileName == name }) else { return }
        let p = expected > 0 ? Double(written) / Double(expected) : 0
        // Throttled: a redraw per 1% is plenty for a progress ring.
        guard abs(p - records[i].progress) >= 0.01 || records[i].bytes == 0 else { return }
        records[i].bytes = written; records[i].expectedBytes = max(expected, 0); records[i].progress = p
    }

    fileprivate func finished(_ name: String, bytes: Int64) {
        guard let i = records.firstIndex(where: { $0.fileName == name }) else {
            try? FileManager.default.removeItem(at: DownloadFiles.url(for: name)); return   // deleted mid-transfer
        }
        records[i].state = .done; records[i].progress = 1; records[i].bytes = bytes
        records[i].expectedBytes = bytes; records[i].error = nil
        save(); pump()
    }

    fileprivate func failed(_ name: String, _ message: String) {
        guard let r = records.first(where: { $0.fileName == name }) else { return }
        fail(r.id, message)
    }

    private func fail(_ id: String, _ message: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        discardFile(records[i])
        records[i].state = .failed; records[i].error = message
        records[i].fileName = nil; records[i].bytes = 0; records[i].progress = 0
        save(); pump()
    }

    fileprivate func finishBackgroundEvents() {
        backgroundCompletion?(); backgroundCompletion = nil
    }

    /// After a relaunch: anything marked downloading without a live transfer goes back in the queue.
    private func reconcile() {
        session.getAllTasks { [weak self] tasks in
            let live = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                guard let self else { return }
                for i in self.records.indices where self.records[i].state == .downloading {
                    if let n = self.records[i].fileName, live.contains(n) { continue }
                    self.records[i].state = .queued; self.records[i].progress = 0; self.records[i].bytes = 0
                }
                self.sweepOrphans()
                self.save(); self.pump()
            }
        }
    }

    /// Files nobody refers to (a crash mid-delete, an abandoned transfer).
    private func sweepOrphans() {
        let known = Set(records.compactMap(\.fileName)).union(["index.json"])
        let files = (try? FileManager.default.contentsOfDirectory(atPath: DownloadFiles.directory.path)) ?? []
        for f in files where !known.contains(f) {
            try? FileManager.default.removeItem(at: DownloadFiles.url(for: f))
        }
    }

    // MARK: Persistence (a file, not UserDefaults: the list can grow)

    private func save() {
        guard let d = try? JSONEncoder().encode(records) else { return }
        try? d.write(to: DownloadFiles.index, options: .atomic)
        DownloadFiles.excludeFromBackup(DownloadFiles.index)
    }

    private static func loadIndex() -> [DownloadRecord] {
        guard let d = try? Data(contentsOf: DownloadFiles.index),
              let r = try? JSONDecoder().decode([DownloadRecord].self, from: d) else { return [] }
        return r
    }
}

// MARK: - URLSession delegate (runs off the main thread)

private final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard let name = downloadTask.taskDescription else { return }
        Task { @MainActor in DownloadManager.shared.progress(name, written: written, expected: expected) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription else { return }
        // A 403 / 404 arrives here as a "successful" download of the error page.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in DownloadManager.shared.failed(name, "Server returned \(http.statusCode)") }
            return
        }
        // The temp file is deleted when this method returns, so the move has to happen here.
        let dest = DownloadFiles.url(for: name)
        do {
            DownloadFiles.prepare()
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            DownloadFiles.excludeFromBackup(dest)
            let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            Task { @MainActor in DownloadManager.shared.finished(name, bytes: size) }
        } catch {
            Task { @MainActor in DownloadManager.shared.failed(name, error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let name = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in DownloadManager.shared.failed(name, error.localizedDescription) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in DownloadManager.shared.finishBackgroundEvents() }
    }
}
