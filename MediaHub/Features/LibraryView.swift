import SwiftUI

/// One page with collapsible sections (Watching, Completed, Plan to Watch), each ordered by most recent activity.
/// Simkl's library when Simkl is connected, otherwise the active profile's local library.
struct LibraryView: View {
    @Environment(SimklStore.self) private var simkl
    @Environment(LocalLibrary.self) private var local
    @Environment(WatchHistory.self) private var history
    @Environment(ProfileStore.self) private var profiles
    /// Comma-separated ids of the collapsed sections; remembered between launches.
    @AppStorage("library.collapsed") private var collapsedRaw = ""
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12, alignment: .top)]

    private struct LibSection: Identifiable {
        let id: String; let title: String; let symbol: String; let items: [MetaPreview]
    }

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ id: String) {
        var s = collapsed
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        withAnimation(.snappy(duration: 0.3)) { collapsedRaw = s.sorted().joined(separator: ",") }
    }

    // MARK: Data

    private var sections: [LibSection] {
        simkl.isConnected ? simklSections : localSections
    }

    /// Simkl returns each list already newest-activity-first (see SimklStore.sync).
    private var simklSections: [LibSection] {
        func items(_ key: String) -> [MetaPreview] { simkl.library.first { $0.id == "simkl-\(key)" }?.items ?? [] }
        return make([("watching", "Watching", "eye.fill", items("watching")),
                     ("completed", "Completed", "checkmark.circle.fill", items("completed")),
                     ("plan", "Plan to Watch", "bookmark.fill", items("plantowatch"))])
    }

    private var localSections: [LibSection] {
        let progress = Dictionary(history.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()

        // Completed: saved titles marked watched, plus movies whose history says they finished.
        var done: [(MetaPreview, Date)] = []
        for e in local.entries where e.status == .watched {
            let played = progress[e.item.id]?.updated ?? e.alias.flatMap { progress[$0]?.updated } ?? .distantPast
            done.append((e.item, max(played, e.added)))
            seen.insert(e.item.id); if let a = e.alias { seen.insert(a) }
        }
        for h in history.entries where h.isFinished && h.item.type != "series" && !seen.contains(h.id) {
            done.append((h.item, h.updated)); seen.insert(h.id)
        }

        // Watching: started and not finished (series count while there is progress), not already completed.
        let watching = history.entries
            .filter { $0.position > 30 && ($0.item.type == "series" || !$0.isFinished) && !seen.contains($0.id) }
            .sorted { $0.updated > $1.updated }
            .map(\.item)

        let plan = local.entries.filter { $0.status == .planToWatch }.sorted { $0.added > $1.added }.map(\.item)
        return make([("watching", "Watching", "eye.fill", watching),
                     ("completed", "Completed", "checkmark.circle.fill", done.sorted { $0.1 > $1.1 }.map(\.0)),
                     ("plan", "Plan to Watch", "bookmark.fill", plan)])
    }

    private func make(_ raw: [(String, String, String, [MetaPreview])]) -> [LibSection] {
        raw.compactMap { id, title, symbol, items in
            items.isEmpty ? nil : LibSection(id: id, title: title, symbol: symbol, items: items)
        }
    }

    private var subtitle: String {
        simkl.isConnected ? "Synced with Simkl" : "\(profiles.active.name) · On this device"
    }

    // MARK: View

    var body: some View {
        let secs = sections
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(secs) { sec in
                        Section {
                            if !collapsed.contains(sec.id) {
                                LazyVGrid(columns: columns, spacing: 18) {
                                    ForEach(sec.items) { PosterCard(item: $0, width: nil, showsTitle: true) }
                                }
                                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 22)
                                .transition(.opacity)
                            }
                        } header: { header(sec) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .overlay {
                if secs.isEmpty {
                    if simkl.isConnected {
                        if simkl.isSyncing { ProgressView() }
                        else { ContentUnavailableView("Nothing here yet", systemImage: "books.vertical",
                            description: Text("Titles you add on Simkl show up here.")) }
                    } else {
                        ContentUnavailableView("Your library is empty", systemImage: "books.vertical",
                            description: Text("Tap Add to Watchlist on any title to save it to \(profiles.active.name)'s library. Connect Simkl in Settings to sync across devices."))
                    }
                }
            }
            .refreshable { await simkl.sync(force: true) }
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationTitle("Library")
            .navigationSubtitle(subtitle)
            .profileToolbar()
        }
    }

    private func header(_ sec: LibSection) -> some View {
        let open = !collapsed.contains(sec.id)
        return Button { toggle(sec.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: sec.symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(.tint)
                Text(sec.title).font(.title3.bold())
                Text("\(sec.items.count)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.down").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 0 : -90))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(sec.title), \(sec.items.count) titles")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(open ? "collapse" : "expand")")
    }
}
