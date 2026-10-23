import SwiftUI

/// The sidebar's "Recently Watched" catalogue page: every title in the active profile's history, newest first.
struct RecentlyWatchedPage: View {
    @Environment(WatchHistory.self) private var history

    var body: some View {
        let sorted: [WatchHistory.Entry] = history.entries.sorted { $0.updated > $1.updated }
        let items: [MetaPreview] = sorted.map(\.item)
        let row: CatalogRow = CatalogRow(id: "local:recently-watched", title: "Recently Watched",
                                         items: items, source: .none)
        Group {
            if sorted.isEmpty {
                ContentUnavailableView("Nothing watched yet", systemImage: "clock")
            } else {
                CatalogGridView(row: row)
            }
        }
        .backShortcuts()
    }
}

/// The sidebar's "Continue Watching" catalogue page: in-progress titles as 16:9 cards in a grid.
struct ContinueWatchingPage: View {
    @Environment(WatchHistory.self) private var history

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

    var body: some View {
        let entries: [WatchHistory.Entry] = history.continueEntries.sorted { $0.updated > $1.updated }
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Nothing in progress", systemImage: "play.circle")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(entries) { entry in
                            ContinueCard(entry: entry, fillsWidth: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Continue Watching")
        .navigationBarTitleDisplayMode(.inline)
        .backShortcuts()
    }
}
