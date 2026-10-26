import SwiftUI

/// The line under the loader, or the buffering spinner, while a torrent opens or buffers: peers, speed, progress.
/// Before the stream has numbers it says it is still looking for peers (same wording as the desktop app).
enum P2PStatusText {
    /// How long each phrase of `FindingPeersPhrases` stays up.
    static let phraseSeconds = 4

    static func line(_ stats: EngineStats?) -> String {
        guard let stats else { return "Finding peers…" }
        var parts = [stats.peersLive == 1 ? "1 peer" : "\(stats.peersLive) peers"]
        if stats.downloadBps > 0 { parts.append("\(rate(stats.downloadBps))/s") }
        if stats.totalBytes > 0 { parts.append("\(stats.downloadedBytes * 100 / stats.totalBytes)%") }
        return parts.joined(separator: " · ")
    }

    /// True while no peer has been found yet: the engine has no numbers, or has them and none of its peers is live.
    static func isLookingForPeers(_ stats: EngineStats?) -> Bool { stats == nil || stats?.peersLive == 0 }

    /// A byte rate as KB or MB with one decimal place.
    static func rate(_ bytesPerSecond: UInt64) -> String {
        if bytesPerSecond >= 1_048_576 {
            let tenths = bytesPerSecond * 10 / 1_048_576
            return "\(tenths / 10).\(tenths % 10) MB"
        }
        return "\(bytesPerSecond / 1024) KB"
    }
}

/// What to say while still looking for peers. The first phrase is the plain "Finding peers…"; after it, `next()` hands out
/// the playful ones in a random order, each once before any comes round again, and never the same one twice in a row.
/// Call `restart()` when peers are found, so the next search begins with the plain line again.
final class FindingPeersPhrases {
    private static let plain = "Finding peers…"
    private static let playful = [
        "Asking around the swarm…",
        "Knocking on strangers' doors…",
        "Shaking the pear. tree…",
        "Waving at the internet…",
        "Bribing seeders with good vibes…",
        "Sending out the pigeons…",
        "Whistling for peers…",
        "Checking behind the couch cushions…",
        "Shouting into the void…",
        "Persuading the router…",
        "Rounding up the swarm…",
        "Peers are shy today…",
        "Following the crumbs…",
        "Polishing the secret handshake…",
    ]

    private var queue: [String] = []
    private var last: String?
    private var started = false

    func next() -> String {
        if !started {
            started = true
            last = Self.plain
            return Self.plain
        }
        if queue.isEmpty { refill() }
        let phrase = queue.removeFirst()
        last = phrase
        return phrase
    }

    func restart() {
        started = false
        queue.removeAll()
        last = nil
    }

    private func refill() {
        var round = Self.playful.shuffled()
        // A new round must not open with the phrase the last one ended on.
        if round.count > 1, round.first == last { round.append(round.removeFirst()) }
        queue = round
    }
}

/// The status text under the player's loader or spinner for a torrent. It polls the engine once a second, and only while
/// it is on screen (no timer runs when the loader or spinner is hidden): a phrase that changes every few seconds while no
/// peer is found, then peers, speed and progress.
struct P2PStatusLabel: View {
    @State private var text = ""

    var body: some View {
        Text(text)
            .font(.archivo(.footnote))
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .animation(.easeInOut(duration: 0.25), value: text)
            .allowsHitTesting(false)
            .task { await poll() }
    }

    private func poll() async {
        let phrases = FindingPeersPhrases()
        var phrase = ""
        var secondsSearching = 0
        while !Task.isCancelled {
            let stats = await P2PManager.shared.statsAsync()
            if P2PStatusText.isLookingForPeers(stats) {
                if secondsSearching % P2PStatusText.phraseSeconds == 0 { phrase = phrases.next() }
                text = phrase
                secondsSearching += 1
            } else {
                text = P2PStatusText.line(stats)
                secondsSearching = 0
                phrases.restart()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
