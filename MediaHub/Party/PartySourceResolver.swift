import Foundation

// Batch S3, watch party source resolution (plan K6). Not compiled: the owner's CI builds it.

/// Picks the stream a guest plays for the room's title, from the guest's own add-ons. The order:
/// (1) the same add-on and release name as the host, (2) the same torrent, only when this device has P2P on,
/// (3) the guest's pinned source for the show, (4) the first playable stream from any add-on.
/// No URL ever comes from the room; everything here comes from this device's add-ons.
enum PartySourceResolver {
    enum Outcome {
        case found(PlayRequest, chip: String)
        case unplayable(reason: String)
    }

    @MainActor
    static func resolve(_ source: PartySource, addons: [Addon], pins: PinnedSources) async -> Outcome {
        let isSeries = source.type == "series"
        let sid: String
        if isSeries {
            guard let season = source.season, let episode = source.episode else {
                return .unplayable(reason: "The host hasn't picked an episode yet.")
            }
            sid = "\(source.imdb):\(season):\(episode)"
        } else {
            sid = source.imdb
        }

        let groups = await AddonClient.shared.streams(for: sid, type: source.type, addons: addons)
        // Task-group results arrive in completion order: keep the user's add-on order.
        let ordered = AddonClient.ordered(groups, by: addons)

        var found: (Addon, StreamItem)?

        // 1. The same add-on and release name as the host.
        if let addonID = source.addonId, let group = ordered.first(where: { $0.0.id == addonID }) {
            let playable = group.1.filter(\.isPlayable)
            if let signature = source.signature {
                if let stream = playable.first(where: { $0.signature == signature }) { found = (group.0, stream) }
            } else if let stream = playable.first {
                found = (group.0, stream)
            }
        }

        // 2. The same torrent. Only playable with P2P on; with it off, say why.
        var torrentSkipped = false
        if found == nil, let hash = source.p2pHash?.lowercased() {
            for group in ordered {
                if let stream = group.1.first(where: { $0.isPlayable && $0.infoHash?.lowercased() == hash }) {
                    found = (group.0, stream)
                    break
                }
            }
            if found == nil, !P2PSettings.isEnabled {
                torrentSkipped = listsTorrent(ordered, hash: hash)
            }
        }

        // 3. This device's pin for the show, 4. the first playable stream from any add-on.
        if found == nil, let pin = pins.pin(for: source.imdb),
           let group = ordered.first(where: { $0.0.id == pin.addonID }) {
            let playable = group.1.filter(\.isPlayable)
            if let stream = playable.first(where: { $0.signature == pin.signature }) ?? playable.first {
                found = (group.0, stream)
            }
        }
        if found == nil {
            for group in ordered {
                if let stream = group.1.first(where: \.isPlayable) {
                    found = (group.0, stream)
                    break
                }
            }
        }

        guard let (addon, stream) = found, let target = stream.playTarget else {
            if torrentSkipped {
                return .unplayable(reason: "The host is watching a torrent. Turn on Peer-to-peer in Settings to play it.")
            }
            return .unplayable(reason: "No playable source on this device for this title.")
        }

        let request = PlayRequest(
            url: target.url, headers: stream.requestHeaders, item: source.item,
            key: isSeries ? "\(source.season ?? 0):\(source.episode ?? 0)" : "movie",
            imdb: source.imdb,
            season: isSeries ? source.season : nil, episode: isSeries ? source.episode : nil,
            episodeTitle: source.episodeTitle, logo: nil, thumb: nil,
            sourceAddonID: addon.id, sourceSignature: stream.signature, p2p: target.p2p)
        return .found(request, chip: chipText(addon: addon, stream: stream))
    }

    /// The short name of the source in use, for the "Your source" line.
    static func chipText(addon: Addon, stream: StreamItem) -> String {
        "\(addon.manifest.name) · \(stream.name ?? stream.title ?? "Stream")"
    }

    /// Whether any add-on lists this torrent (it is there, just switched off here).
    private static func listsTorrent(_ groups: [(Addon, [StreamItem])], hash: String) -> Bool {
        groups.contains { $0.1.contains { $0.infoHash?.lowercased() == hash } }
    }
}

extension PartySource {
    /// The title as the player and the title pages know it. A guest only has the IMDb id, the name and the year.
    var item: MetaPreview {
        MetaPreview(id: imdb, type: type, name: title, poster: nil, background: nil, logo: nil,
                    description: nil, releaseInfo: year.map { String($0) })
    }
}
