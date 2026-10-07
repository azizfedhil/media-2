import SwiftUI

/// Apple TV-style episode card: the still fades into a dark, softly tinted panel with
/// "EPISODE 1", the title, a short description, the runtime and a "..." menu.
/// The tint is the still's average colour (cached by ImagePipeline), so each card gets its own mood for one tiny request.
struct EpisodeCard<Actions: View>: View {
    let ep: EpisodeItem
    let selected: Bool
    let watched: Bool
    var upNext = false
    /// Download state for this episode (nil = not downloaded): drives the badge.
    var download: DownloadRecord? = nil
    let onTap: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(ThemeStore.self) private var theme
    @State private var tint: Color?

    static var width: CGFloat { 250 }
    static var height: CGFloat { 292 }
    private let radius: CGFloat = 22

    /// Not aired yet: the artwork is greyed out and the card says when it comes out.
    private var upcoming: Bool { ep.isUpcoming }

    private var runtime: String? {
        guard let m = ep.runtime, m > 0 else { return nil }
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m") : "\(m)m"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.09)
            if let tint { tint.opacity(0.3).transition(.opacity) }
            // Still across the top ~60%, dissolving into the panel instead of ending at an edge.
            StillImage(url: ep.image, size: Self.height * 0.62 * 16 / 9)
                // Only the artwork fades: the panel stays dark so the white text keeps its contrast.
                .saturation(upcoming ? 0.1 : 1)
                .opacity(upcoming ? 0.5 : 1)
                .frame(width: Self.width, height: Self.height * 0.62)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }
        }
        .frame(width: Self.width, height: Self.height)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                if watched { badge("checkmark.circle.fill", "Watched") }
                else if upNext { badge(nil, "UP NEXT", fill: theme.accent, text: theme.onAccent) }
                if let download { downloadBadge(download, below: watched || upNext) }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let r = ep.rating, r > 0 { ratingBadge(r) }
        }
        .overlay(alignment: .bottomLeading) { text }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        // Deliberately faint: the card is already busy with artwork and text, so the selection should whisper.
        .selectionRing(selected, radius: radius, width: 1, intensity: 0.35)
        // Whole card opens the sources sheet; the "..." sits on top so it takes its own taps.
        .overlay { Button(action: onTap) { Color.clear.contentShape(Rectangle()) }.buttonStyle(PressableStyle()) }
        .overlay(alignment: .bottomTrailing) {
            Menu { actions() } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 40).contentShape(Rectangle())
            }
            .padding(.trailing, 6).padding(.bottom, 6)
        }
        .contextMenu { actions() }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(.easeOut(duration: 0.3), value: tint == nil)
        .task(id: ep.image) {
            tint = nil
            guard let u = ep.image, let c = await ImagePipeline.shared.averageColor(for: u), !Task.isCancelled else { return }
            tint = Color(uiColor: c)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EPISODE \(ep.id)").font(.system(size: 12, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.white.opacity(0.65))
            Text(ep.name).font(.system(size: 18, weight: .bold)).lineLimit(1)
                .opacity(upcoming ? 0.7 : 1)
            if let o = ep.overview, !o.isEmpty {
                Text(o).font(.system(size: 13)).foregroundStyle(.white.opacity(upcoming ? 0.5 : 0.7)).lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            Group {
                if let airs = ep.airsOn {
                    Label("Airs on \(airs)", systemImage: "calendar")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                } else {
                    Text(runtime ?? " ").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    /// Episode ratings come from TMDB, so the badge carries the TMDB mark.
    private func ratingBadge(_ r: Double) -> some View {
        HStack(spacing: 5) {
            RatingLogo(label: "TMDB", height: 11)
            Text(String(format: "%.1f", r)).monospacedDigit()
        }
        .font(.caption2.bold()).foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
        .allowsHitTesting(false)
    }

    /// Saved / saving state. Solid accent once the file is on the device.
    private func downloadBadge(_ d: DownloadRecord, below: Bool) -> some View {
        let symbol: String, label: String
        switch d.state {
        case .done: symbol = "arrow.down.circle.fill"; label = "Downloaded"
        case .downloading: symbol = "arrow.down.circle"; label = "\(Int(d.progress * 100))%"
        case .queued: symbol = "clock"; label = "Queued"
        case .failed: symbol = "exclamationmark.triangle.fill"; label = "Failed"
        }
        let done = d.state == .done
        return HStack(spacing: 4) { Image(systemName: symbol); Text(label).monospacedDigit() }
            .font(.caption2.bold()).foregroundStyle(done ? theme.onAccent : .white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(done ? theme.accent : Color.black.opacity(0.55), in: Capsule())
            .padding(.leading, 10).padding(.top, below ? 0 : 10)
            .allowsHitTesting(false)
    }

    private func badge(_ symbol: String?, _ label: String, fill: Color = .black.opacity(0.55), text: Color = .white) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(label)
        }
        .font(.caption2.bold()).foregroundStyle(text)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(fill, in: Capsule())
        .padding(10)
        .allowsHitTesting(false)
    }
}
