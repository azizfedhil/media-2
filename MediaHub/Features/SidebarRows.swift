import SwiftUI

/// Shared colours for the sidebar panel. Kept in one place so switching the selection to the theme's accent
/// later is a one-line change.
enum SidebarMetrics {
    static let selectedFill: Color = .white
    static let selectedForeground: Color = .black
    static let panelColor: Color = Color(white: 0.07)
    static let hairline: Color = Color.white.opacity(0.07)
}

/// One of the five destination rows at the top of the sidebar. Selected rows are a solid white pill with
/// black icon and text, as on the desktop app.
struct SidebarNavRow: View {
    let tab: AppTab
    let selected: Bool
    let compact: Bool
    let action: () -> Void

    @State private var hovering = false

    private var fill: Color {
        if selected { return SidebarMetrics.selectedFill }
        if hovering { return Color.white.opacity(0.08) }
        return Color.clear
    }

    private var foreground: Color {
        selected ? SidebarMetrics.selectedForeground : Color.white.opacity(0.78)
    }

    private var titleWeight: Font.Weight {
        selected ? .bold : .medium
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 24)
                if !compact {
                    Text(tab.title)
                        .font(.archivo(size: 16, weight: titleWeight))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: selected)
        .animation(.snappy(duration: 0.15), value: hovering)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Sidebar column

/// The part of the sidebar under the five tabs: Continue Watching, the pinned titles and the catalogues.
/// It is one vertical scroll, as on the desktop app. Only drawn in the full sidebar; the icon-only fold keeps the tabs.
struct SidebarColumn: View {
    @Binding var catalogueID: String?
    let catalogues: [CatalogueRef]

    @Environment(WatchHistory.self) private var history
    @Environment(SidebarPins.self) private var sidebarPins

    @State private var expanded = false

    private static let continueID = "local:continue-watching"
    private static let recentlyWatchedID = "local:recently-watched"

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                continueBlock
                if !sidebarPins.items.isEmpty { pinnedBlock }
                cataloguesBlock
                Color.clear.frame(height: 8)
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Continue Watching

    private var recent: [WatchHistory.Entry] {
        let sorted: [WatchHistory.Entry] = history.continueEntries.sorted { $0.updated > $1.updated }
        return Array(sorted.prefix(3))
    }

    private var continueBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            SidebarContinueHeader(selected: catalogueID == Self.continueID) {
                catalogueID = Self.continueID
            }
            ForEach(recent) { entry in
                SidebarContinueRow(entry: entry)
            }
        }
        .padding(.top, 12)
    }

    // MARK: Pinned

    private var pinnedBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            SidebarSectionLabel(title: "Pinned")
            ForEach(sidebarPins.items) { item in
                SidebarPinnedRow(item: item)
            }
        }
    }

    // MARK: Catalogues

    private var catalogueRows: [SidebarCatalogue] {
        let recentRow = SidebarCatalogue(id: Self.recentlyWatchedID, title: "Recently Watched")
        let addons: [SidebarCatalogue] = catalogues.map { SidebarCatalogue(id: $0.id, title: $0.title) }
        return [recentRow] + addons
    }

    private var cataloguesBlock: some View {
        let rows: [SidebarCatalogue] = catalogueRows
        let overflow = rows.count > 5
        let forcedOpen = rows.firstIndex { $0.id == catalogueID }.map { $0 >= 5 } ?? false
        let open = expanded || forcedOpen
        let shown: [SidebarCatalogue] = (open || !overflow) ? rows : Array(rows.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            SidebarSectionLabel(title: "Catalogues")
            VStack(alignment: .leading, spacing: 3) {
                ForEach(shown) { row in
                    SidebarCatalogueRow(item: row, selected: catalogueID == row.id) {
                        catalogueID = row.id
                    }
                }
                if overflow && !open {
                    SidebarCataloguePeek(item: rows[5]) {
                        withAnimation(.snappy) { expanded = true }
                    }
                }
                if overflow && !forcedOpen {
                    SidebarShowMoreRow(open: open) {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                }
            }
        }
    }
}

private struct SidebarContinueHeader: View {
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var color: Color {
        if selected { return .white }
        return hovering ? Color.white.opacity(0.85) : Color.white.opacity(0.5)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Continue Watching")
                    .font(.archivo(.subheadline, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SidebarContinueRow: View {
    let entry: WatchHistory.Entry

    @Environment(WatchHistory.self) private var history
    @Environment(ShellNav.self) private var shellNav
    @State private var hovering = false

    private var stillURL: URL? {
        entry.thumb.flatMap(URL.init(string:)) ?? entry.item.backdropURL ?? entry.item.posterURL
    }

    private var subtitle: String {
        let percent = Int((entry.progress * 100).rounded())
        if let se = entry.seasonEpisode {
            return "S\(se.season) · E\(se.episode) · \(percent)%"
        }
        if let year = entry.item.year {
            return "\(year) · \(percent)%"
        }
        return "\(percent)%"
    }

    private var fill: Color {
        hovering ? Color.white.opacity(0.08) : Color.clear
    }

    private func open() {
        shellNav.push(ResumeTarget(item: entry.item,
                                   season: entry.seasonEpisode?.season,
                                   episode: entry.seasonEpisode?.episode))
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    StillImage(url: stillURL, size: 48)
                        .frame(width: 48, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .background(Color.white.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.item.name)
                            .font(.archivo(.footnote, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.archivo(.caption))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .lineLimit(1)
                        progressBar.padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            menuButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu { menuContent }
    }

    private var progressBar: some View {
        let fraction: CGFloat = CGFloat(max(entry.progress, 0.05))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color(hex: "#8B6EF5") ?? .purple)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    private var menuButton: some View {
        Menu {
            menuContent
        } label: {
            SidebarEllipsisLabel()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    @ViewBuilder private var menuContent: some View {
        Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
            history.remove(entry.id)
            history.dismissUpNext(entry.id)
        }
        PosterContextMenu(item: entry.item, artwork: false, onDetails: { shellNav.push(entry.item) })
    }
}

private struct SidebarPinnedRow: View {
    let item: MetaPreview

    @Environment(SidebarPins.self) private var sidebarPins
    @Environment(ShellNav.self) private var shellNav
    @State private var hovering = false

    private var fill: Color {
        hovering ? Color.white.opacity(0.08) : Color.clear
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                shellNav.push(item)
            } label: {
                HStack(spacing: 10) {
                    RotatingArtwork(item: item, kind: .poster, size: 60)
                        .frame(width: 28, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .background(Color.white.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(item.name)
                        .font(.archivo(.footnote, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                menuContent
            } label: {
                SidebarEllipsisLabel()
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu { menuContent }
    }

    @ViewBuilder private var menuContent: some View {
        Button("Unpin from Sidebar", systemImage: "pin.slash") {
            sidebarPins.unpin(item.id)
        }
        PosterContextMenu(item: item, artwork: false, onDetails: { shellNav.push(item) })
    }
}

private struct SidebarEllipsisLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.6))
            .frame(width: 22, height: 22)
            .background(Color.white.opacity(0.1), in: Circle())
            .contentShape(Circle())
    }
}

private struct SidebarCatalogue: Identifiable {
    let id: String
    let title: String
}

private struct SidebarSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.archivo(.subheadline, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.5))
            .lineLimit(1)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.top, 28)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarCatalogueRow: View {
    let item: SidebarCatalogue
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var fill: Color {
        if selected { return SidebarMetrics.selectedFill }
        return hovering ? Color.white.opacity(0.08) : Color.clear
    }

    private var foreground: Color {
        selected ? SidebarMetrics.selectedForeground : Color.white.opacity(0.85)
    }

    private var weight: Font.Weight {
        selected ? .semibold : .medium
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SidebarBrandBadge(title: item.title)
                Text(item.title)
                    .font(.archivo(.footnote, weight: weight))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SidebarBrandBadge: View {
    let title: String

    private var brand: (background: Color, label: String?) {
        let lower = title.lowercased()
        if lower.contains("max") { return (Color(hex: "#002BE7") ?? .blue, "max") }
        if lower.contains("prime") { return (Color(hex: "#00A8E1") ?? .cyan, "prime") }
        if lower.contains("starz") { return (Color.black, "STARZ") }
        if lower.contains("netflix") { return (Color(hex: "#E50914") ?? .red, "N") }
        return (Color.white.opacity(0.15), nil)
    }

    var body: some View {
        let badge = brand
        ZStack {
            Circle().fill(badge.background)
            if let label = badge.label {
                Text(label)
                    .font(.archivo(size: 7, weight: .black))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct SidebarCataloguePeek: View {
    let item: SidebarCatalogue
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            SidebarCatalogueRow(item: item, selected: false, action: {})
                .allowsHitTesting(false)
        }
        .frame(height: 26, alignment: .top)
        .clipped()
        .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

private struct SidebarShowMoreRow: View {
    let open: Bool
    let action: () -> Void

    @State private var hovering = false

    private var color: Color {
        hovering ? Color.white.opacity(0.85) : Color.white.opacity(0.55)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(open ? "Show less" : "Show more")
                    .font(.archivo(.footnote, weight: .medium))
                    .lineLimit(1)
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
