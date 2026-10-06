import Foundation

/// One shared, cache-aware client. HTTP caching (ETag / Cache-Control) is honored by URLCache,
/// so repeat launches don't refetch catalogs the add-on says are still fresh.
actor AddonClient {
    static let shared = AddonClient()
    private let session: URLSession
    /// Stream lookups get their own session so a slow catalog fetch never queues behind them (and vice versa).
    /// It shares the URLCache object with `session`, so `clearCache()` still clears everything.
    private let streamSession: URLSession
    /// Hard ceiling per add-on. The URLSession timeout is an idle timeout; a trickling response could outlive it.
    private static let streamDeadline: Duration = .seconds(8)

    init() {
        let cache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 150 << 20)
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = cache
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 12
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg)

        let sc = URLSessionConfiguration.default
        sc.urlCache = cache
        sc.requestCachePolicy = .useProtocolCachePolicy
        sc.timeoutIntervalForRequest = 8
        sc.httpMaximumConnectionsPerHost = 8
        streamSession = URLSession(configuration: sc)
    }

    /// Stream-lookup fetch with a real 8 s deadline (the fetch races a timer).
    private func streamData(_ url: URL) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (d, resp) = try await self.streamSession.data(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return d
            }
            group.addTask {
                try await Task.sleep(for: Self.streamDeadline)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let d = try await group.next() else { throw URLError(.cannotLoadFromNetwork) }
            return d
        }
    }

    private func data(_ url: URL, fresh: Bool = false) async throws -> Data {
        var req = URLRequest(url: url)
        if fresh { req.cachePolicy = .reloadIgnoringLocalCacheData }
        let (d, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    func manifest(at url: URL, fresh: Bool = false) async throws -> AddonManifest {
        try JSONDecoder().decode(AddonManifest.self, from: try await data(url, fresh: fresh))
    }

    /// Drops every cached catalog / manifest response, so the next fetch goes to the network.
    func clearCache() { session.configuration.urlCache?.removeAllCachedResponses() }

    /// `skip` pages through add-ons that declare it; `search` queries add-ons that declare it.
    func catalog(addon: Addon, catalog: AddonManifest.CatalogDef, skip: Int = 0, search: String? = nil) async throws -> [MetaPreview] {
        var extras: [String] = []
        if let q = search?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            extras.append("search=" + (q.addingPercentEncoding(withAllowedCharacters: safe) ?? q))
        }
        if skip > 0 { extras.append("skip=\(skip)") }
        var path = "catalog/\(catalog.type)/\(catalog.id)"
        if !extras.isEmpty { path += "/" + extras.joined(separator: "&") }
        // Built as a string: appendingPathComponent would double-encode the % escapes.
        guard let url = URL(string: addon.baseURL.absoluteString + path + ".json") else { throw URLError(.badURL) }
        return try MetaPreview.decodeList(try await data(url))
    }

    /// Fans out only to add-ons that declare the `stream` resource for this type/id, and yields each add-on's
    /// result the moment it answers (completion order; use `ordered(_:by:)` to restore the user's add-on order).
    /// Add-ons that fail or time out are simply skipped. Cancelling the consumer cancels the lookups.
    nonisolated func streamUpdates(for id: String, type: String, addons: [Addon]) -> AsyncStream<(Addon, [StreamItem])> {
        AsyncStream { cont in
            let task = Task {
                // Warm the path monitor now so P2PGate.ready() rarely has to wait for the first path update.
                if P2PSettings.isEnabled { P2PNetwork.shared.start() }
                await withTaskGroup(of: (Addon, [StreamItem])?.self) { group in
                    for addon in addons where addon.provides("stream", type: type, id: id) {
                        group.addTask {
                            let url = addon.baseURL.appendingPathComponent("stream/\(type)/\(id).json")
                            guard let d = try? await self.streamData(url),
                                  let s = try? StreamItem.decodeList(d) else { return nil }
                            return (addon, await P2PGate.apply(s))
                        }
                    }
                    for await r in group { if let r { cont.yield(r) } }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Same fan-out, waits for everyone. Signature unchanged for Downloads and episode switching.
    func streams(for id: String, type: String, addons: [Addon]) async -> [(Addon, [StreamItem])] {
        var out: [(Addon, [StreamItem])] = []
        for await r in streamUpdates(for: id, type: type, addons: addons) { out.append(r) }
        return out
    }

    /// Sorts results into the user's add-on order.
    nonisolated static func ordered(_ groups: [(Addon, [StreamItem])], by addons: [Addon]) -> [(Addon, [StreamItem])] {
        addons.compactMap { a in groups.first(where: { $0.0.id == a.id }) }
    }
}
