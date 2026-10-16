import Foundation

// Batch S2, watch party logic. Not compiled: the owner's CI builds it.

extension PartySource {
    /// The room's description of what this device is playing. It carries no stream URL.
    init(request: PlayRequest) {
        self.init(
            type: request.item.type == "series" ? "series" : "movie",
            imdb: request.imdb.isEmpty ? request.item.id : request.imdb,
            title: request.item.name,
            year: Self.year(from: request.item.releaseInfo),
            season: request.season,
            episode: request.episode,
            episodeTitle: request.episodeTitle,
            addonId: request.sourceAddonID,
            signature: request.sourceSignature,
            p2pHash: request.p2p?.infoHash,
            fileIdx: request.p2p?.fileIdx,
            poster: nil
        )
    }

    /// The JSON object the wire takes. Nil fields are left out.
    var wireObject: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// The first four digits of a release string such as "2019" or "2019-".
    private static func year(from releaseInfo: String?) -> Int? {
        guard let releaseInfo, releaseInfo.count >= 4,
              let year = Int(releaseInfo.prefix(4)), (1900...2100).contains(year) else { return nil }
        return year
    }
}
