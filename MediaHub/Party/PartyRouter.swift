import Foundation
import Observation

// Batch S3, watch party routing. Not compiled: the owner's CI builds it.

/// What the root of the app presents for a party: the guest's party player, and a title a host picked from a suggestion.
/// The player and the title page can't be opened from inside a full-screen cover, so they are presented from `RootView`.
@MainActor @Observable
final class PartyRouter {
    static let shared = PartyRouter()

    /// The guest's party player is open (presented from `RootView`).
    var guestPlayerOpen = false
    /// A title to open on its page (from the host's "Watch this" on a suggestion).
    var openTitle: MetaPreview?

    private init() {}

    /// Opens the guest's party player. A moment later, so a sheet that is still closing does not swallow the presentation.
    func openGuestPlayer() {
        guard !guestPlayerOpen else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guestPlayerOpen = true
        }
    }

    /// What the guest's player starts with: nothing to play yet. The room's source replaces it when it arrives.
    static func placeholderRequest() -> PlayRequest {
        PlayRequest(
            url: URL(string: "about:blank")!, headers: [:],
            item: MetaPreview(id: "", type: "movie", name: "Watch party", poster: nil, background: nil, logo: nil,
                              description: nil, releaseInfo: nil),
            key: "", imdb: "", season: nil, episode: nil)
    }
}
