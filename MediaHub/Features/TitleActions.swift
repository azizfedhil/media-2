import SwiftUI

/// Shared actions behind the long-press menus on posters, seasons and episodes.
/// "Watched" lives in the watch history (a finished entry drives Up Next and clears Continue Watching);
/// library membership is LocalLibrary when Simkl isn't connected (Simkl's own library syncs itself).
@MainActor
enum TitleActions {
    /// Marks a whole title watched via the show-level flag only. No progress record is created and no
    /// fabricated season-total duration is written, so this can never leak into Continue Watching or
    /// imply watched state for individual episodes beyond the explicit whole-show flag.
    static func markWatched(_ item: MetaPreview, history: WatchHistory) {
        history.setSeriesWatched(item.id, watched: true)
    }

    static func unmarkWatched(_ item: MetaPreview, history: WatchHistory) {
        history.clearWatched(item.id)
    }

    /// Marks exactly one episode watched/unwatched — nothing else in the show changes.
    static func setEpisodeWatched(_ item: MetaPreview, history: WatchHistory, season: Int, episode: Int, watched: Bool) {
        history.setEpisodeWatched(item.id, season: season, episode: episode, watched: watched)
    }


    /// Adds to the local library as planned, or flips an existing saved entry to watched.
    static func addToList(_ item: MetaPreview, library: LocalLibrary) {
        library.set(item, status: library.entry(for: item.id) == nil ? .planToWatch : .watched)
    }

    static func removeFromList(_ item: MetaPreview, library: LocalLibrary) {
        library.remove(item.id)
    }
}

/// The long-press ("dropdown") menu shown on any poster: watched state, list membership, and Details.
struct PosterContextMenu: View {
    let item: MetaPreview
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library

    /// Whole-title watched state: the explicit flag, or every listed episode marked (movies have no
    /// episodes, so the show-level flag is what counts there). Never inferred from playback position.
    private var isWatched: Bool { history.isSeriesWatched(item.id) }
    private var inList: Bool { library.entry(for: item.id) != nil }

    var body: some View {
        Button {
            if isWatched { TitleActions.unmarkWatched(item, history: history) }
            else { TitleActions.markWatched(item, history: history) }
        } label: {
            Label(isWatched ? "Unmark as Watched" : "Mark as Watched",
                  systemImage: isWatched ? "circle" : "checkmark.circle")
        }
        Button {
            if inList { TitleActions.removeFromList(item, library: library) }
            else { library.set(item, status: .planToWatch) }
        } label: {
            Label(inList ? "Remove from Library" : "Add to Library",
                  systemImage: inList ? "bookmark.slash" : "bookmark")
        }
        NavigationLink(value: item) {
            Label("Details", systemImage: "info.circle")
        }
    }
}

extension View {
    /// Long-press menu for posters in carousels and grids. The card keeps its tap-to-open behaviour;
    /// this adds the dropdown with watched / library / details actions.
    func posterContextMenu(_ item: MetaPreview) -> some View {
        contextMenu { PosterContextMenu(item: item) }
    }
}
