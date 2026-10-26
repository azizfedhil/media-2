import Foundation

/// The playful lines under the launch animation. One is picked at random each launch (same list as the desktop app).
enum LaunchPhrases {
    static let all: [String] = [
        "Pear-ing up the good stuff…",
        "Getting a-pear-ently ready…",
        "Pear-fect timing…",
        "Ripening the pixels…",
        "Polishing the pear. to a shine…",
        "Shaking the pear. tree…",
        "Teaching the pear. to dance…",
        "Pear-sonalizing your evening…",
        "Plucking today's picks…",
        "Peeling back the layers…",
        "Popping the popcorn…",
        "Dimming the lights…",
        "Fluffing the couch cushions…",
        "Warming up the couch…",
        "Almost ripe…",
        "Grabbing the good seats…",
    ]

    static func pick() -> String { all.randomElement() ?? all[0] }
}
