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

/// Which orientations the app may rotate to right now. The app's own mask is portrait on iPhone (landscape too once
/// the landscape layout is switched on in Settings) and everything on iPad; the player narrows it to landscape.
/// `AppDelegate` reports this mask to UIKit; `set` changes it and rotates the screen to match.
enum OrientationLock {
    /// What the rest of the app (everything but the player) is allowed to do.
    static var appMask: UIInterfaceOrientationMask {
        // The simulated iPad rotates with the phone. The player still narrows this to landscape through `set`.
        if WideLayout.simulatingPad { return .allButUpsideDown }
        if WideLayout.isRealPad { return .all }
        return UserDefaults.standard.bool(forKey: WideLayout.phoneKey) ? .allButUpsideDown : .portrait
    }
    static var mask: UIInterfaceOrientationMask = OrientationLock.appMask

    @MainActor
    static func set(_ new: UIInterfaceOrientationMask) {
        mask = new
        // The player (landscape only) owns the screen: the layout mode holds still until it is gone.
        LayoutState.shared.playerOpen = (new == .landscape)
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
    @State private var sidebarPins = SidebarPins()
    @State private var shellNav = ShellNav()
    @State private var libraryPrefs = LibraryPrefs()
    @State private var contentPrefs = ContentPrefs()
    @State private var downloads = DownloadManager.shared
    @State private var connectivity = Connectivity.shared
    @State private var mediaServers = MediaServerStore.shared
    /// First launch only: the setup flow (see `Onboarding`).
    @State private var showOnboarding = Onboarding.needed

    init() {
        // Builds the "pear." animation outlines in the background so the intro starts on its first frame.
        Task.detached(priority: .userInitiated) { _ = PearGeometry.shared }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .background { PointerInputHost().allowsHitTesting(false) }
                .fullScreenCover(isPresented: $showOnboarding) { OnboardingView { showOnboarding = false } }
                .environment(store).environment(history).environment(simkl).environment(pins).environment(theme)
                .environment(profiles).environment(library).environment(sidebarPins).environment(watchLog).environment(libraryPrefs)
                .environment(contentPrefs).environment(downloads).environment(connectivity).environment(mediaServers)
                .environment(shellNav)
                .preferredColorScheme(Theme.forceDark ? .dark : nil)
                .pearLaunchScreen()
        }
        .commands {
            GoCommands(shellNav: shellNav)
        }
    }
}

/// The "Go" menu: the same destinations and actions the desktop app offers, with their keyboard shortcuts.
struct GoCommands: Commands {
    let shellNav: ShellNav

    var body: some Commands {
        CommandMenu("Go") {
            Button("Home") { AppCommands.shared.tabRequest = .home }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(LayoutState.shared.playerOpen)
            Button("Explore") { AppCommands.shared.tabRequest = .explore }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(LayoutState.shared.playerOpen)
            Button("Library") { AppCommands.shared.tabRequest = .library }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(LayoutState.shared.playerOpen)
            Button("Settings") { AppCommands.shared.tabRequest = .settings }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(LayoutState.shared.playerOpen)
            Button("Search") {
                AppCommands.shared.tabRequest = .search
                AppCommands.shared.pendingSearchFocus = true
                AppCommands.shared.searchFocusTick += 1
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(LayoutState.shared.playerOpen)
            Button("Back") {
                _ = shellNav.back()
                AppCommands.shared.backTick += 1
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(LayoutState.shared.playerOpen)
            Button("Reload") {
                if shellNav.current == .home && !shellNav.catalogueActive {
                    NotificationCenter.default.post(name: Notification.Name("pear.refresh"), object: nil)
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(LayoutState.shared.playerOpen)
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
    @Environment(SidebarPins.self) private var sidebarPins
    @Environment(WatchLog.self) private var watchLog
    @Environment(LibraryPrefs.self) private var libraryPrefs
    @Environment(ContentPrefs.self) private var contentPrefs
    @Environment(AddonStore.self) private var addonStore
    @Environment(PinnedSources.self) private var pinnedSources
    @Environment(DownloadManager.self) private var downloads
    @Environment(Connectivity.self) private var connectivity
    @Environment(ShellNav.self) private var shellNav
    /// True when the app launched without a connection: shows the Downloads page instead of the (empty) online tabs.
    @State private var offlineMode = false
    /// Watch party: the guest's player and a title to open from a suggestion (see PartyRouter).
    @Bindable private var router = PartyRouter.shared
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(WideLayout.phoneKey) private var phoneLandscape = false
    @AppStorage(WideLayout.simulateKey) private var ipadMode = false
    @State private var layoutState = LayoutState.shared
    @State private var commands = AppCommands.shared
    @State private var tab: AppTab = .home
    @State private var wide = WideLayout.isPad
    /// Window size, seeded from the screen so the very first frame already picks the right sidebar width.
    /// In iPad mode this is the virtual window's size, not the phone's.
    @State private var size: CGSize = {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let real = scene?.effectiveGeometry.coordinateSpace.bounds.size ?? .zero
        return WideLayout.simulatingPad ? WideLayout.virtualPadSize(for: real) : real
    }()

    var body: some View {
        Group {
            if WideLayout.simulatingPad {
                VirtualPadWindow {
                    browsing
                }
            } else {
                browsing
            }
        }
        // The developer toggle: let the phone rotate with the virtual iPad, and pick the new layout at once.
        .onChange(of: ipadMode) { _, _ in
            OrientationLock.set(OrientationLock.appMask)
            updateWide()
        }
        .onChange(of: hSize) { _, _ in updateWide() }
        .onChange(of: phoneLandscape) { _, _ in updateWide() }
        .onChange(of: layoutState.playerOpen) { _, _ in updateWide() }
        .tint(theme.accent)
        // With the neutral accent, switches would otherwise turn white-on-white; keep the stock green.
        .toggleStyle(SwitchToggleStyle(tint: theme.isSystem ? .green : theme.accent))
        // Each profile has its own watch history and local library; swap them when the profile changes.
        .onChange(of: profiles.activeID, initial: true) { _, id in
            history.load(profile: id)
            library.load(profile: id)
            sidebarPins.load(profile: id)
            watchLog.load(profile: id)
            libraryPrefs.load(profile: id)
            contentPrefs.load(profile: id)
        }
        .sensoryFeedback(.selection, trigger: profiles.activeID)
        .task { await refreshLibrary() }
        // Pear.pair: the Simkl state decides whether the library is synced, then the sync starts if an account is signed in.
        .task {
            let simklStore = simkl
            let watchLogStore = watchLog
            PairSync.shared.simklConnected = { simklStore.isConnected }
            // The watch log's unsaved seconds go in before a merge, and the live log reads storage again after one.
            PairSync.shared.flushWatchLog = { watchLogStore.flush() }
            PairSync.shared.watchLogStored = { watchLogStore.reloadKeepingUnsaved() }
            PairSync.shared.startIfSignedIn()
        }
        // A pull changed this device's data: the stores read it again.
        .onReceive(NotificationCenter.default.publisher(for: PairSync.remoteApplied)) { _ in
            profiles.reload()
            history.reload()
            library.reload()
            sidebarPins.reload()
            libraryPrefs.reload()
            watchLog.reloadKeepingUnsaved()
            contentPrefs.reload()
        }
        // A pull wrote shared settings. The stores that keep them in memory read them again; the rest read UserDefaults
        // or @AppStorage directly and update by themselves.
        .onReceive(NotificationCenter.default.publisher(for: PairSync.settingsApplied)) { note in
            let keys = (note.userInfo?["keys"] as? Set<String>) ?? []
            if keys.contains(where: { $0.hasPrefix("content.prefs") }) { contentPrefs.reload() }
            if keys.contains(where: { $0.hasPrefix("addon.") }) { Task { await addonStore.reloadFromDefaults() } }
            if keys.contains(where: { $0.hasPrefix("ui.") }) { theme.reload() }
        }
        .task { downloads.configure(store: addonStore, pins: pinnedSources) }
        // No connection at launch: start on the Downloads page (no slide-in animation, so it is simply the first screen).
        .task {
            let online = await connectivity.ready()
            guard !online, !Onboarding.isPending else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { offlineMode = true }
        }
        .fullScreenCover(isPresented: $offlineMode) { OfflineHome { offlineMode = false } }
        .fullScreenCover(isPresented: $router.guestPlayerOpen) {
            PlayerScreen(request: PartyRouter.placeholderRequest(), provider: nil,
                         onClose: { router.guestPlayerOpen = false }, partyGuest: true)
        }
        .sheet(item: $router.openTitle) { item in
            NavigationStack { DetailView(item: item) }
        }
        .onChange(of: connectivity.isOnline) { _, on in if on == true { downloads.networkReturned() } }
        .onChange(of: phase) { _, p in
            P2PManager.shared.scenePhaseChanged(p)
            if p == .active {
                PartySession.shared.reconnectNow()
                PairSync.shared.foreground()
                ArtworkRotation.shared.refresh()          // the only place the day's artwork can change
                MediaServerStore.shared.warm()
                Task { await refreshLibrary() }
            } else {
                watchLog.flush()
                ArtworkPool.shared.flush()
                Task { await TMDBClient.shared.flushPending(); await LogoResolver.shared.flush() }
            }
        }
    }

    /// Sidebar layout on iPad (and on iPhone in landscape when switched on); the system TabView everywhere else,
    /// which gives the Liquid Glass tab bar for free. The selected tab carries over between the two.
    @ViewBuilder private var browsing: some View {
        Group {
            if wide {
                SidebarShell(tab: $tab, totalWidth: size.width)
            } else {
                TabView(selection: $tab) {
                    Tab("Home", systemImage: "house.fill", value: AppTab.home) { HomeView() }
                    Tab("Explore", systemImage: "safari.fill", value: AppTab.explore) { ExploreView() }
                    Tab("Library", systemImage: "books.vertical.fill", value: AppTab.library) { LibraryView() }
                    Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) { SettingsView() }
                    Tab(value: AppTab.search, role: .search) { SearchView() }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                .onAppear {
                    shellNav.current = tab
                    shellNav.catalogueActive = false
                }
                .onChange(of: tab) { _, t in
                    shellNav.current = t
                    shellNav.catalogueActive = false
                }
                .onChange(of: commands.tabRequest) { _, requested in
                    guard let requested else { return }
                    tab = requested
                    commands.tabRequest = nil
                }
            }
        }
        // Inside the virtual window this reports its size; outside it reports the real window.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0; updateWide() }
    }

    /// Re-evaluates which layout to use. Held still while the player is open (it forces landscape).
    private func updateWide() {
        guard !layoutState.playerOpen else { return }
        let now = WideLayout.isWide(size: size, hSize: hSize, phoneOptIn: phoneLandscape)
        if now != wide { wide = now }
    }

    /// Foreground refresh, and only what this profile actually uses: automatic sync when it is on, Simkl's lists when
    /// Simkl is the library, nothing at all for a purely local library. Both paths are throttled to once per 15 minutes.
    private func refreshLibrary() async {
        guard simkl.isConnected else { return }
        if libraryPrefs.autoSync && libraryPrefs.source(simkl) != .pair {
            await libraryPrefs.sync(simkl: simkl, library: library, history: history, force: false)
        } else if libraryPrefs.usesSimkl(simkl) {
            await simkl.sync()
        }
    }
}

/// The real screen size and window safe areas, read from UIKit because the GeometryReader proxy can be stale
/// after a rotation.
private enum VirtualPadMetrics {
    static var screenSize: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.effectiveGeometry.coordinateSpace.bounds.size ?? .zero
    }

    static var safeAreaInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.keyWindow?.safeAreaInsets ?? .zero
    }
}

/// Draws the app in a fixed iPad-sized window, scaled down and centred on black, while the developer's iPad mode is on.
private struct VirtualPadWindow<Content: View>: View {
    let content: Content
    @State private var screen: CGSize = VirtualPadMetrics.screenSize

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { _ in
            let real = screen
            let virtual = WideLayout.virtualPadSize(for: real)
            let scale = min(real.width / virtual.width, real.height / virtual.height)
            let fitted = CGSize(width: virtual.width * scale, height: virtual.height * scale)
            let insets = VirtualPadMetrics.safeAreaInsets
            ZStack(alignment: .topLeading) {
                Color.black
                content
                    // The fake iPad traits the pages read: wide everywhere, like a real iPad.
                    .environment(\.horizontalSizeClass, .regular)
                    .environment(\.verticalSizeClass, .regular)
                    // Fake iPad safe areas, so the real notch and home indicator do not become huge scaled gaps.
                    // These sit inside the window's frame (not outside it): applied after a fixed frame they would
                    // stack on top of the window's height, pushing the bottom ~44pt of the app past the window edge.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear.frame(height: 24).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: 20).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .frame(width: virtual.width, height: virtual.height, alignment: .topLeading)
                    // Draw the window like an iPad screen: nothing spills past its edge, and its corners are rounded.
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
                    .offset(x: (real.width - fitted.width) / 2, y: (real.height - fitted.height) / 2)

                Button {
                    UserDefaults.standard.set(false, forKey: WideLayout.simulateKey)
                } label: {
                    Label("Exit iPad mode", systemImage: "xmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .pearGlass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Exit iPad mode")
                .padding(.top, insets.top + 12)
                .padding(.leading, insets.left)
                .padding(.trailing, insets.right + 12)
                .frame(width: real.width, height: real.height, alignment: .topTrailing)
            }
            .frame(width: real.width, height: real.height, alignment: .topLeading)
            .clipped()
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { refreshScreen() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            refreshScreen()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            refreshScreen()
        }
    }

    private func refreshScreen() {
        let current = VirtualPadMetrics.screenSize
        guard current != .zero, current != screen else { return }
        screen = current
    }
}
