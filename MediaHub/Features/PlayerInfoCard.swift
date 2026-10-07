import SwiftUI

/// What the player's info card shows for the episode (or movie) that is playing now.
struct PlayerInfo {
    /// "Dark Matter · S2 · E6" for an episode; nil for a movie.
    var kicker: String?
    var title: String
    /// Episode still, or the movie's backdrop.
    var image: URL?
    var overview: String?
    /// Shown above the synopsis when the episode has none and the series' own description stands in.
    var overviewNote: String?
    /// Already formatted ("June 12, 2025", or just the year when that is all that is known).
    var date: String?
    /// Minutes.
    var runtime: Int?
    var ratings: [MDBListClient.Rating] = []

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2025-06-12" -> "June 12, 2025". nil when the string is missing or not a date.
    static func pretty(_ s: String?) -> String? {
        guard let s, let d = isoDay.date(from: s) else { return nil }
        return d.formatted(date: .long, time: .omitted)
    }
}

/// Content of the info card opened by tapping the title: thumbnail on the left; title, date, runtime, ratings and
/// synopsis on the right. No background of its own: the player puts it on its glass card.
struct PlayerInfoCard: View {
    let info: PlayerInfo
    let onClose: () -> Void

    private static let thumbWidth: CGFloat = 220

    private var runtimeText: String? {
        guard let m = info.runtime, m > 0 else { return nil }
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m") : "\(m) min"
    }

    private var metaLine: String? {
        let parts = [info.date, runtimeText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                header
                if let metaLine {
                    Text(metaLine).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
                if !info.ratings.isEmpty { ratingsRow }
                synopsis
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var thumbnail: some View {
        ZStack {
            Color.white.opacity(0.08)
            StillImage(url: info.image, size: Self.thumbWidth)
        }
        .frame(width: Self.thumbWidth, height: Self.thumbWidth * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let k = info.kicker {
                    Text(k.uppercased()).font(.caption.weight(.bold)).tracking(0.8)
                        .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Text(info.title).font(.system(size: 21, weight: .bold)).lineLimit(2)
            }
            Spacer(minLength: 0)
            // Mirrors the chevron on the title that opened this card.
            Button(action: onClose) {
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32).background(.white.opacity(0.16), in: Circle())
                    .padding(6).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Close")
        }
    }

    private var ratingsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(info.ratings) { RatingBadge(rating: $0, flat: true) }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Plain text when it fits; scrolls when a long synopsis would push the card off a landscape phone.
    @ViewBuilder private var synopsis: some View {
        if let o = info.overview, !o.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let n = info.overviewNote {
                    Text(n.uppercased()).font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.white.opacity(0.5))
                }
                ViewThatFits(in: .vertical) {
                    text(o)
                    ScrollView { text(o) }.scrollIndicators(.hidden)
                }
                .frame(maxHeight: 112)
            }
            .padding(.top, 2)
        }
    }

    private func text(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
