import SwiftUI
import UIKit

/// Static look-and-feel constants. The accent colour itself is user-chosen: see `ThemeStore`.
enum Theme {
    static let defaultHex = "#7D5CFF"      // electric violet
    /// Stored in place of a hex value: no accent colour, the neutral iOS look (white in dark mode, black in light mode).
    static let systemHex = "system"
    static let presets: [(name: String, hex: String)] = [
        ("Violet", "#7D5CFF"), ("Pink", "#FF5C8D"), ("Blue", "#2F80FF"), ("Cyan", "#14B8D4"),
        ("Green", "#22C55E"), ("Gold", "#F5B301"), ("Orange", "#FF8A1F"), ("Red", "#EF4444"),
    ]
    /// Colourful glows and hero art read best on black. Set to false to follow the system appearance.
    static let forceDark = true
}

/// The user's accent colour. Views read it from the environment, so changing it in Settings updates the whole app live.
@MainActor @Observable
final class ThemeStore {
    private(set) var hex: String

    init() { hex = UserDefaults.standard.string(forKey: "ui.accent") ?? Theme.defaultHex }

    func reload() { hex = UserDefaults.standard.string(forKey: "ui.accent") ?? Theme.defaultHex }

    func setAccent(hex: String) {
        self.hex = hex
        UserDefaults.standard.set(hex, forKey: "ui.accent")
    }

    var isSystem: Bool { hex == Theme.systemHex }
    private static let neutral = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : .black })
    private static let neutralInverse = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })

    var accent: Color {
        if isSystem { return Self.neutral }
        return Color(hex: hex) ?? Color(hex: Theme.defaultHex) ?? .purple
    }
    /// A neighbouring hue, for gradients (progress bars, glows).
    var accent2: Color {
        if isSystem { return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.68, alpha: 1) : UIColor(white: 0.32, alpha: 1) }) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(accent).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Near-white / grey accents have no hue to shift, so step the brightness down instead.
        if s < 0.12 { return Color(hue: 0, saturation: 0, brightness: Double(b > 0.5 ? max(b - 0.3, 0) : min(b + 0.3, 1))) }
        return Color(hue: Double((h + 0.1).truncatingRemainder(dividingBy: 1)), saturation: Double(min(s, 0.9)), brightness: Double(min(b + 0.1, 1)))
    }
    /// Text/icon colour that stays readable on top of the accent (black on white or other light accents, white otherwise).
    var onAccent: Color { isSystem ? Self.neutralInverse : accent.contrastingForeground }
    var gradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing) }
}

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    /// Black on light colours, white on dark ones (WCAG relative luminance).
    var contrastingForeground: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return lum > 0.5 ? .black : .white
    }
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

/// Which orientations the app may rotate to right now. Portrait everywhere except the player (landscape only).
/// `AppDelegate` reports this mask to UIKit; `set` changes it and rotates the screen to match.
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait

    @MainActor
    static func set(_ new: UIInterfaceOrientationMask) {
        mask = new
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        // Tell every controller in the presented chain to re-read the supported orientations.
        var vc = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        while let v = vc {
            v.setNeedsUpdateOfSupportedInterfaceOrientations()
            vc = v.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: new)) { _ in }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    /// iOS relaunches the app to hand over finished background downloads; the manager reports back when it's done.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { DownloadManager.shared.backgroundCompletion = completionHandler }
    }
}

@main
struct MediaHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AddonStore()
    @State private var history = WatchHistory()
    @State private var watchLog = WatchLog()
    @State private var simkl = SimklStore()
    @State private var pins = PinnedSources()
    @State private var theme = ThemeStore()
    @State private var profiles = ProfileStore()
    @State private var library = LocalLibrary()
    @State private var libraryPrefs = LibraryPrefs()
    @State private var downloads = DownloadManager.shared
    @State private var connectivity = Connectivity.shared

    init() {
        // Builds the "pear." animation outlines in the background so the intro starts on its first frame.
        Task.detached(priority: .userInitiated) { _ = PearGeometry.shared }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store).environment(history).environment(simkl).environment(pins).environment(theme)
                .environment(profiles).environment(library).environment(watchLog).environment(libraryPrefs)
                .environment(downloads).environment(connectivity)
                .preferredColorScheme(Theme.forceDark ? .dark : nil)
                .pearLaunchScreen()
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(SimklStore.self) private var simkl
    @Environment(ThemeStore.self) private var theme
    @Environment(ProfileStore.self) private var profiles
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library
    @Environment(WatchLog.self) private var watchLog
    @Environment(LibraryPrefs.self) private var libraryPrefs
    @Environment(AddonStore.self) private var addonStore
    @Environment(PinnedSources.self) private var pinnedSources
    @Environment(DownloadManager.self) private var downloads
    @Environment(Connectivity.self) private var connectivity
    /// True when the app launched without a connection: shows the Downloads page instead of the (empty) online tabs.
    @State private var offlineMode = false

    var body: some View {
        // System TabView gives Liquid Glass tab bar for free.
        TabView {
            Tab("Home", systemImage: "house.fill") { HomeView() }
            Tab("Explore", systemImage: "safari.fill") { ExploreView() }
            Tab("Library", systemImage: "books.vertical.fill") { LibraryView() }
            Tab("Settings", systemImage: "gearshape.fill") { SettingsView() }
            Tab(role: .search) { SearchView() }
        }
        .tint(theme.accent)
        // With the neutral accent, switches would otherwise turn white-on-white; keep the stock green.
        .toggleStyle(SwitchToggleStyle(tint: theme.isSystem ? .green : theme.accent))
        .tabBarMinimizeBehavior(.onScrollDown)
        // Each profile has its own watch history and local library; swap them when the profile changes.
        .onChange(of: profiles.activeID, initial: true) { _, id in
            history.load(profile: id)
            library.load(profile: id)
            watchLog.load(profile: id)
            libraryPrefs.load(profile: id)
        }
        .sensoryFeedback(.selection, trigger: profiles.activeID)
        .task { await refreshLibrary() }
        .task { downloads.configure(store: addonStore, pins: pinnedSources) }
        // No connection at launch: start on the Downloads page (no slide-in animation, so it is simply the first screen).
        .task {
            let online = await connectivity.ready()
            guard !online else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { offlineMode = true }
        }
        .fullScreenCover(isPresented: $offlineMode) { OfflineHome { offlineMode = false } }
        .onChange(of: connectivity.isOnline) { _, on in if on == true { downloads.networkReturned() } }
        .onChange(of: phase) { _, p in
            P2PManager.shared.scenePhaseChanged(p)
            if p == .active {
                ArtworkRotation.shared.refresh()          // the only place the day's artwork can change
                Task { await refreshLibrary() }
            } else {
                watchLog.flush()
                ArtworkPool.shared.flush()
            }
        }
    }

    /// Foreground refresh, and only what this profile actually uses: automatic sync when it is on, Simkl's lists when
    /// Simkl is the library, nothing at all for a purely local library. Both paths are throttled to once per 15 minutes.
    private func refreshLibrary() async {
        guard simkl.isConnected else { return }
        if libraryPrefs.autoSync {
            await libraryPrefs.sync(simkl: simkl, library: library, history: history, force: false)
        } else if libraryPrefs.usesSimkl(simkl) {
            await simkl.sync()
        }
    }
}
