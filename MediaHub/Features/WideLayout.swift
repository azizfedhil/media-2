import SwiftUI
import UIKit

/// How the sidebar is drawn in the wide layout. Device-local: it never travels with Pear.pair or a backup.
enum SidebarStyle: String, CaseIterable, Identifiable {
    case liquid, frosted, flat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquid: return "Liquid"
        case .frosted: return "Frosted"
        case .flat: return "Flat"
        }
    }
}

/// Programmatic navigation for the six stacks: one path per tab plus the sidebar's catalogue page.
/// The shell sets `current` / `catalogueActive`; pages push and pop through `push(_:)` / `back()`.
@MainActor @Observable
final class ShellNav {
    var paths: [AppTab: NavigationPath] = [:]
    var cataloguePath = NavigationPath()
    var current: AppTab = .home
    var catalogueActive = false
    var activeFold: FeedCollapse?
    /// Pages currently on screen in each stack that asked to draw under the sidebar (see `sidebarBleed()`).
    private(set) var bleeders: [String: Set<UUID>] = [:]

    func setBleeding(_ key: String, _ token: UUID, _ on: Bool) {
        var set = bleeders[key] ?? []
        if on { set.insert(token) } else { set.remove(token) }
        if set != (bleeders[key] ?? []) { bleeders[key] = set }
    }

    /// True while a page that bleeds is showing in this stack.
    func isBleeding(_ key: String) -> Bool { !(bleeders[key] ?? []).isEmpty }

    init() {
        for tab in AppTab.allCases { paths[tab] = NavigationPath() }
    }

    func push<V: Hashable>(_ value: V) {
        if catalogueActive {
            cataloguePath.append(value)
        } else {
            var path = paths[current] ?? NavigationPath()
            path.append(value)
            paths[current] = path
        }
    }

    @discardableResult
    func back() -> Bool {
        if catalogueActive {
            guard !cataloguePath.isEmpty else { return false }
            cataloguePath.removeLast()
            return true
        }
        var path = paths[current] ?? NavigationPath()
        guard !path.isEmpty else { return false }
        path.removeLast()
        paths[current] = path
        return true
    }

    func binding(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[tab] ?? NavigationPath() },
            set: { self.paths[tab] = $0 }
        )
    }

    var catalogueBinding: Binding<NavigationPath> {
        Binding(
            get: { self.cataloguePath },
            set: { self.cataloguePath = $0 }
        )
    }
}

extension View {
    /// The destinations every tab stack and the catalogue page register.
    func shellDestinations() -> some View {
        self
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: ResumeTarget.self) { DetailView(item: $0.item, startSeason: $0.season, startEpisode: $0.episode) }
            .navigationDestination(for: CatalogRow.self) { row in PushedFoldPage { CatalogGridView(row: row) } }
    }
}

// MARK: - When is the wide layout used?

/// Shared flag: the player owns the screen. While it is up the layout mode is frozen, so rotating into the
/// player's landscape can't swap the app's structure out from under the page that presented it.
@MainActor @Observable
final class LayoutState {
    static let shared = LayoutState()
    var playerOpen = false

    /// How many sheets are up over the pages (see `coversPages()`).
    private(set) var coverDepth = 0
    /// True while a sheet sits over the pages. Nothing behind it needs to move: the hero auto-advance, its zoom and
    /// progress bar, and the shimmer sweeps all rest until it is dismissed, like they do for a page that is off screen.
    var pagesCovered: Bool { coverDepth > 0 }
    func cover() { coverDepth += 1 }
    func uncover() { coverDepth = max(coverDepth - 1, 0) }
}

/// Holds the wide layout's source picker while a detail page has it open. The page fills this in; the shell draws it
/// above the sidebar, because a page's own overlay can't cover the sidebar sitting next to it.
@MainActor @Observable
final class SourcePickerHost {
    static let shared = SourcePickerHost()
    var isPresented = false
    var content: AnyView?
    var owner: UUID?
    private init() {}
}

/// Whether the last input came from a pointer (trackpad / mouse) rather than a finger. Set on the shell container:
/// a hover marks the pointer active, a drag marks it inactive. The player reads it to pick its pointer behaviour.
@MainActor @Observable
final class InputState {
    static let shared = InputState()
    var pointerActive = false
}

/// Requests raised by the menu bar (see `GoCommands`). The shell and `SearchView` observe these and act on them.
@MainActor @Observable
final class AppCommands {
    static let shared = AppCommands()
    var tabRequest: AppTab?
    var backTick: Int = 0
    /// Bumped when ⌘F is used, so `SearchView` focuses its field again even if it was already on screen.
    var searchFocusTick: Int = 0
    /// Set when ⌘F is used; `SearchView` consumes it on appear when the tab was not mounted yet.
    var pendingSearchFocus = false
}

private struct CoversPages: ViewModifier {
    @State private var counted = false
    func body(content: Content) -> some View {
        content
            .onAppear { if !counted { counted = true; LayoutState.shared.cover() } }
            .onDisappear { if counted { counted = false; LayoutState.shared.uncover() } }
    }
}

extension View {
    /// Put on the root of a sheet that covers the browsing pages. While it is presented, animation behind it rests.
    /// Apply it outside any NavigationStack inside the sheet: pushing a page there must not count as the sheet leaving.
    func coversPages() -> some View { modifier(CoversPages()) }
}

enum WideLayout {
    /// iPhone opt-in (Settings → Appearance). Off by default.
    static let phoneKey = "ui.landscapeLayout"

    /// Developer toggle (About → Developer). Renders the app on an iPhone as if it were an iPad.
    static let simulateKey = "dev.ipadMode"

    /// The 11-inch iPad Pro's points, in both orientations.
    static let padPortraitSize = CGSize(width: 834, height: 1194)
    static let padLandscapeSize = CGSize(width: 1194, height: 834)

    static var isRealPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var simulatingPad: Bool {
        UserDefaults.standard.bool(forKey: simulateKey) && UIDevice.current.userInterfaceIdiom == .phone
    }
    static var isPad: Bool { isRealPad || simulatingPad }

    /// The virtual window size that matches the phone's current orientation.
    static func virtualPadSize(for real: CGSize) -> CGSize {
        real.width > real.height ? padLandscapeSize : padPortraitSize
    }

    /// iPad: whenever there is room for it (full screen, or a wide split view; Slide Over falls back to tabs).
    /// iPhone: only when the toggle is on and the phone is in landscape. The developer toggle always reports wide.
    static func isWide(size: CGSize, hSize: UserInterfaceSizeClass?, phoneOptIn: Bool) -> Bool {
        if simulatingPad { return true }
        if isPad { return hSize == .regular }
        return phoneOptIn && size.width > size.height
    }
}

private struct PageActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False while a page is kept alive but is not the one on screen. The sidebar layout hides visited pages with
    /// opacity instead of removing them, so `onAppear` / `onDisappear` never fire for them. Anything that loops or
    /// animates on its own (hero auto-advance, Ken Burns) reads this and rests while it is false.
    var pageActive: Bool {
        get { self[PageActiveKey.self] }
        set { self[PageActiveKey.self] = newValue }
    }
}

private struct WideLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside the sidebar layout. Views use it to pick bigger posters, skip the avatar button, and so on.
    var wideLayout: Bool {
        get { self[WideLayoutKey.self] }
        set { self[WideLayoutKey.self] = newValue }
    }
}

/// Kill switch. Set to false to make every page simply start beside the sidebar.
/// With it on, only the pages that call `sidebarBleed()` (the Home hero, a title's poster) draw beneath the glass
/// sidebar, exactly as on the desktop app. Every other page is laid out beside it.
enum WideLayoutConfig { static let bleedUnderSidebar = true }

private struct ShellStackKey: EnvironmentKey { static let defaultValue = "none" }
extension EnvironmentValues {
    /// Which navigation stack of the shell a page lives in ("tab-home", "catalogue", ...). Pages that bleed report
    /// themselves under this key, so the shell knows whether the stack's visible page may sit under the sidebar.
    var shellStackKey: String {
        get { self[ShellStackKey.self] }
        set { self[ShellStackKey.self] = newValue }
    }
}

private struct SidebarInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    /// Room the sidebar takes at the leading edge while pages may draw beneath it.
    var sidebarInset: CGFloat {
        get { self[SidebarInsetKey.self] }
        set { self[SidebarInsetKey.self] = newValue }
    }
}

private struct SidebarBleedsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True when pages may extend under the sidebar instead of starting beside it.
    var sidebarBleeds: Bool {
        get { self[SidebarBleedsKey.self] }
        set { self[SidebarBleedsKey.self] = newValue }
    }
}

private struct SidebarBleedModifier: ViewModifier {
    @Environment(\.sidebarBleeds) private var sidebarBleeds
    @Environment(\.shellStackKey) private var stackKey
    @Environment(ShellNav.self) private var shellNav
    @State private var token = UUID()

    /// One code path on purpose: the shell flips `sidebarBleeds` once this page has reported in, and a branch here
    /// would change the page's identity and throw its state away. The page reports whether or not it may bleed yet,
    /// so the shell can give its stack the room (and the page the sidebar inset) on the next pass.
    func body(content: Content) -> some View {
        let edges: Edge.Set = sidebarBleeds ? Edge.Set.leading : Edge.Set()
        return content
            .ignoresSafeArea(.container, edges: edges)
            .onAppear { shellNav.setBleeding(stackKey, token, true) }
            .onDisappear { shellNav.setBleeding(stackKey, token, false) }
    }
}

extension View {
    /// Let this page draw under the sidebar, when the shell allows it.
    func sidebarBleed() -> some View { modifier(SidebarBleedModifier()) }

    /// Command-[ and Escape go back, like the desktop app. Applied to pages that sit inside a navigation stack.
    func backShortcuts() -> some View { modifier(BackShortcuts()) }
}

private struct BackShortcuts: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pageActive) private var pageActive

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                Button { dismiss() } label: { Color.clear.frame(width: 1, height: 1) }
                    .keyboardShortcut("[", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .frame(width: 0, height: 0)
                Button { dismiss() } label: { Color.clear.frame(width: 1, height: 1) }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .frame(width: 0, height: 0)
            }
            .disabled(!pageActive)
        }
    }
}

/// How far the wide layout is folded: the pane's vertical scroll and the horizontal drag of a row inside it both
/// push the poster panel away. Zero is fully open; one is fully folded.
@MainActor @Observable
final class FeedCollapse {
    // Raw scroll values change on every frame of a scroll, so they are kept out of observation: nothing re-renders
    // for them. Views read `folded`, which only changes when the fold crosses a threshold.
    @ObservationIgnored var vertical: CGFloat = 0
    @ObservationIgnored private var rows: [AnyHashable: CGFloat] = [:]

    /// Whether the layout is folded: the poster panel is away and the sidebar is at icon width. It flips once as the
    /// scroll crosses a threshold, with a gap between the two so it does not flutter near the line, and the layout
    /// animates that one change. Folding follows the finger frame by frame used to re-lay out the whole page on
    /// every frame of a scroll, which is what made scrolling drop frames on a phone.
    private(set) var folded = false

    /// Where a scroll bucket stands as a fraction of a full fold (see `bucket`).
    nonisolated static let bucketFractions: [CGFloat] = [0, 0.05, 0.2, 1]

    /// A scroll position as 0...1 of a full fold, reduced to four buckets. A scroll view's change callback only
    /// fires when this value changes, so it runs a few times per scroll instead of once per frame.
    nonisolated static func bucket(_ fraction: CGFloat) -> Int {
        fraction <= 0 ? 0 : (fraction < 0.08 ? 1 : (fraction < 0.35 ? 2 : 3))
    }

    func setVertical(bucket b: Int) {
        vertical = Self.bucketFractions[min(max(b, 0), 3)]
        if b == 0 { rows.removeAll() }
        settle()
    }

    func report(_ id: AnyHashable, bucket b: Int) {
        rows[id] = Self.bucketFractions[min(max(b, 0), 3)]
        settle()
    }
    func forget(_ id: AnyHashable) { rows[id] = nil; settle() }
    func expand() { rows.removeAll(); vertical = 0; settle() }

    var progress: CGFloat { max(vertical, rows.values.max() ?? 0) }

    private func settle() {
        let p = progress
        if !folded, p >= 0.35 { folded = true } else if folded, p <= 0.08 { folded = false }
    }
}

private struct FeedCollapseKey: EnvironmentKey { static let defaultValue: FeedCollapse? = nil }
extension EnvironmentValues {
    /// The live fold shared by `CollapsingSplit`, `PaneScroll` and the rows inside the pane.
    var feedCollapse: FeedCollapse? {
        get { self[FeedCollapseKey.self] }
        set { self[FeedCollapseKey.self] = newValue }
    }
}

// MARK: - Tabs

enum AppTab: Hashable, CaseIterable, Identifiable {
    case search, home, explore, settings, library
    var id: Self { self }

    /// Sidebar order.
    static let sidebarOrder: [AppTab] = [.search, .home, .explore, .settings, .library]

    var title: String {
        switch self {
        case .search: "Search"
        case .home: "Home"
        case .explore: "Explore"
        case .settings: "Settings"
        case .library: "Library"
        }
    }
    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house.fill"
        case .explore: "safari"
        case .settings: "gearshape.fill"
        case .library: "books.vertical.fill"
        }
    }
}

/// An add-on catalogue listed under "Catalogues" in the sidebar, or one of the local history pages.
struct CatalogueRef: Identifiable {
    enum Kind {
        case addon(Addon, AddonManifest.CatalogDef)
        case local(String)
    }

    static let continueWatchingID = "local:continue-watching"
    static let recentlyWatchedID = "local:recently-watched"

    let kind: Kind

    init(addon: Addon, def: AddonManifest.CatalogDef) {
        kind = .addon(addon, def)
    }

    init(localID: String) {
        kind = .local(localID)
    }

    var id: String {
        switch kind {
        case .addon(let addon, let def):
            return "\(addon.id)/\(def.type)/\(def.id)"
        case .local(let id):
            return id
        }
    }

    var title: String {
        switch kind {
        case .addon(_, let def):
            let media = def.type == "movie" ? "Movies" : def.type == "series" ? "Series" : def.type.capitalized
            return "\(def.name ?? def.id) \(media)"
        case .local(let id):
            return id == Self.continueWatchingID ? "Continue Watching" : "Recently Watched"
        }
    }
}

// MARK: - Sidebar shell

/// iPad (and opt-in iPhone landscape) container: profile + clock, the five destinations and the add-on catalogues
/// down the left; the selected page on the right. Pages that were opened stay alive while hidden, so each keeps
/// its own navigation stack and scroll position, like the tabs do.
struct SidebarShell: View {
    @Binding var tab: AppTab
    /// Full width of the window, used to pick between the full and the icon-only sidebar.
    let totalWidth: CGFloat

    @Environment(ProfileStore.self) private var profiles
    @Environment(SimklStore.self) private var simkl
    @Environment(AddonStore.self) private var store
    @Environment(ContentPrefs.self) private var contentPrefs
    @Environment(ShellNav.self) private var shellNav
    @AppStorage("ui.sidebarStyle") private var storedStyle: String = "liquid"
    @State private var visited: Set<AppTab> = [.home]
    @State private var catalogueID: String?
    @State private var showProfile = false
    /// One fold per tab, so a page's scroll and row drags move only its own tab's state.
    @State private var tabFolds: [AppTab: FeedCollapse] = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, FeedCollapse()) })
    /// The sidebar catalogue pages share one fold; it is reset each time a different catalogue opens.
    @State private var catalogueFold = FeedCollapse()
    @State private var commands = AppCommands.shared
    @State private var sourcePicker = SourcePickerHost.shared

    private var baseWidth: CGFloat { totalWidth >= 1000 ? 250 : (totalWidth >= 780 ? 212 : 76) }
    /// The fold of the page on screen: the open catalogue's, else the selected tab's.
    private var visibleFold: FeedCollapse? { catalogueID != nil ? catalogueFold : tabFolds[tab] }
    private var fold: CGFloat {
        if let active = shellNav.activeFold { return active.folded ? 1 : 0 }
        return (visibleFold?.folded ?? false) ? 1 : 0
    }
    private var compact: Bool {
        let width: CGFloat = baseWidth + (76 - baseWidth) * fold
        return fold > 0.45 || width < 100
    }

    private var effectiveSidebarStyle: SidebarStyle {
        if PowerMode.shared.lowPower || PowerMode.shared.saving { return .flat }
        return SidebarStyle(rawValue: storedStyle) ?? .liquid
    }
    private var isGlass: Bool { effectiveSidebarStyle != .flat }
    private var bleeds: Bool { WideLayoutConfig.bleedUnderSidebar && isGlass }

    private var catalogues: [CatalogueRef] {
        HomeModel.homeJobs(addons: store.enabledAddons, rules: contentPrefs.rules, pickers: store.pickerIDs)
            .map { CatalogueRef(addon: $0.0, def: $0.1) }
    }

    var body: some View {
        let fold: CGFloat = self.fold
        let width: CGFloat = baseWidth + (76 - baseWidth) * fold
        let inset: CGFloat = bleeds ? width : 0
        ZStack(alignment: .leading) {
            pages(width: width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.sidebarBleeds, bleeds)
                .environment(\.sidebarInset, inset)
            sidebar(width: width)
            if let overlay = sourcePicker.content, sourcePicker.isPresented {
                overlay
                    .ignoresSafeArea()
                    .coversPages()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(100)
            }
            if showProfile {
                profileOverlay(width: width)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                    .zIndex(200)
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .environment(\.wideLayout, true)
        .animation(.easeInOut(duration: 0.22), value: fold)
        .onContinuousHover { phase in
            if case .active = phase, !InputState.shared.pointerActive {
                InputState.shared.pointerActive = true
            }
        }
        .onChange(of: tab, initial: true) { _, t in
            visited.insert(t)
            shellNav.current = t
        }
        .onChange(of: catalogueID, initial: true) { _, id in
            shellNav.catalogueActive = (id != nil)
            // A catalogue opens at the top, so its fold starts open too.
            catalogueFold.expand()
        }
        .onChange(of: commands.tabRequest) { _, requested in
            guard let requested else { return }
            selectTab(requested)
            shellNav.cataloguePath = NavigationPath()
            commands.tabRequest = nil
        }
        .onAppear {
            shellNav.current = tab
            shellNav.catalogueActive = (catalogueID != nil)
        }
    }

    // MARK: Floating profile

    private func profileOverlay(width: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.black.opacity(0.10))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeProfile() }
                ProfileSheet(floating: true, onClose: closeProfile)
                    .frame(width: 380)
                    .frame(maxHeight: max(geo.size.height - 32, 0))
                    .background {
                        Color.clear.pearGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                    .contentShape(Rectangle())
                    .padding(.leading, width + 12)
                    .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }

    private func closeProfile() {
        withAnimation(.easeOut(duration: 0.18)) { showProfile = false }
    }

    // MARK: Pages

    private func shown(_ t: AppTab) -> Bool { catalogueID == nil && tab == t }

    /// Desktop rule: a page that bleeds (Home's hero, a title's poster) starts at the window edge and is told how far
    /// the sidebar covers it. Every other page gets the sidebar's width as real layout space, so its title, lists and
    /// sideways-scrolling rows are laid out and clipped beside the sidebar and can never slide under it.
    /// Home's root counts as bleeding before it has reported in, so it does not jump on launch.
    private func stackBleeds(_ key: String, home: Bool = false) -> Bool {
        guard bleeds else { return false }
        if shellNav.isBleeding(key) { return true }
        return home && (shellNav.paths[.home]?.isEmpty ?? true)
    }

    @ViewBuilder
    private func stack<V: View>(_ key: String, width: CGFloat, home: Bool = false, @ViewBuilder _ content: () -> V) -> some View {
        let b: Bool = stackBleeds(key, home: home)
        content()
            .padding(.leading, b ? 0 : width)
            .safeAreaPadding(.leading, b ? width : 0)
            .environment(\.sidebarBleeds, b)
            .environment(\.sidebarInset, b ? width : 0)
            .environment(\.shellStackKey, key)
    }

    private func pages(width: CGFloat) -> some View {
        ZStack {
            ForEach(AppTab.allCases) { t in
                if visited.contains(t) || tab == t {
                    stack("tab-\(t)", width: width, home: t == .home) { page(t) }
                        .environment(\.pageActive, shown(t))
                        .environment(\.feedCollapse, tabFolds[t])
                        .opacity(shown(t) ? 1 : 0)
                        .allowsHitTesting(shown(t))
                        .accessibilityHidden(!shown(t))
                }
            }
            if let id = catalogueID {
                if let ref = catalogues.first(where: { $0.id == id }) {
                    stack("catalogue", width: width) { CataloguePage(ref: ref).id(ref.id) }
                        .environment(\.feedCollapse, catalogueFold)
                } else if id.hasPrefix("local:") {
                    let ref = CatalogueRef(localID: id)
                    stack("catalogue", width: width) { CataloguePage(ref: ref).id(ref.id) }
                        .environment(\.feedCollapse, catalogueFold)
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: [stackBleeds("tab-\(tab)", home: tab == .home), stackBleeds("catalogue")])
    }

    @ViewBuilder private func page(_ t: AppTab) -> some View {
        switch t {
        case .home: HomeView()
        case .explore: ExploreView()
        case .library: LibraryView()
        case .settings: SettingsView()
        case .search: SearchView()
        }
    }

    // MARK: Sidebar

    private var sidebarHorizontalPadding: CGFloat {
        switch effectiveSidebarStyle {
        case .liquid: return compact ? 4 : 12
        case .flat, .frosted: return compact ? 8 : 16
        }
    }

    @ViewBuilder
    private var sidebarBacking: some View {
        switch effectiveSidebarStyle {
        case .flat:
            SidebarMetrics.panelColor
        case .frosted:
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(SidebarMetrics.panelColor.opacity(0.5))
            }
        case .liquid:
            Color.clear.pearGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                                  tint: SidebarMetrics.panelColor.opacity(0.25))
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 6) { ForEach(AppTab.sidebarOrder) { navRow($0) } }
            if compact {
                Spacer(minLength: 0)
            } else {
                SidebarColumn(catalogueID: $catalogueID, catalogues: catalogues)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // The list's scroll view bleeds into the bottom safe area, which would draw its rows (and
                    // "Show less") below the panel. Keep them inside the panel.
                    .clipped()
            }
        }
        .padding(.horizontal, sidebarHorizontalPadding)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func sidebar(width: CGFloat) -> some View {
        switch effectiveSidebarStyle {
        case .liquid:
            sidebarContent
                .background { sidebarBacking }
                .contentShape(Rectangle())
                .onTapGesture {}
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 8)
                .frame(width: width)
                .frame(maxHeight: .infinity)
        case .flat, .frosted:
            sidebarContent
                .background {
                    ZStack(alignment: .trailing) {
                        sidebarBacking
                        Rectangle().fill(SidebarMetrics.hairline).frame(width: 0.5)
                    }
                    .ignoresSafeArea()
                }
                .contentShape(Rectangle())
                .onTapGesture {}
                .frame(width: width)
                .frame(maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.18)) { showProfile = true } } label: {
                HStack(spacing: 10) {
                    ProfileAvatar(profile: profiles.active, size: 34)
                    if !compact {
                        Text(simkl.name(for: profiles.active))
                            .font(.archivo(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        TimelineView(.everyMinute) { ctx in
                            Text(ctx.date.formatted(date: .omitted, time: .shortened))
                                .font(.archivo(.footnote))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .padding(.horizontal, compact ? 0 : 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
            .accessibilityValue(simkl.name(for: profiles.active))

            if !compact {
                PearWordmark(height: 24)
                    .padding(.leading, 6)
                    .padding(.top, 16)
            }
        }
        .padding(.bottom, 22)
    }

    private func navRow(_ t: AppTab) -> some View {
        SidebarNavRow(tab: t, selected: catalogueID == nil && tab == t, compact: compact) {
            selectTab(t)
        }
    }

    private func selectTab(_ t: AppTab) {
        let wasCatalogue = catalogueID != nil
        let sameTab = t == tab && !wasCatalogue
        catalogueID = nil
        tab = t
        if wasCatalogue { shellNav.cataloguePath = NavigationPath() }
        if sameTab { shellNav.paths[t] = NavigationPath() }
    }
}

/// One add-on catalogue as a full page (the sidebar entry), with the usual endless poster grid.
private struct CataloguePage: View {
    let ref: CatalogueRef
    @Environment(ContentPrefs.self) private var contentPrefs
    @Environment(ShellNav.self) private var shellNav
    @State private var row: CatalogRow?
    @State private var failed = false

    var body: some View {
        NavigationStack(path: shellNav.catalogueBinding) {
            if case .local(let id) = ref.kind {
                localPage(id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                    .shellDestinations()
            } else {
                Group {
                    if let row { CatalogGridView(row: row) }
                    else if failed { ContentUnavailableView("Couldn't load this catalogue", systemImage: "wifi.slash") }
                    else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .shellDestinations()
            }
        }
        .task(id: ref.id) {
            guard case .addon(let addon, let def) = ref.kind else { return }
            let raw = (try? await AddonClient.shared.catalog(addon: addon, catalog: def)) ?? []
            guard !Task.isCancelled else { return }
            guard !raw.isEmpty else { failed = true; return }
            let items = await TitleClassifier.shared.filter(raw, rules: contentPrefs.rules)
            row = CatalogRow(id: ref.id, title: ref.title, items: items, source: .addon(addon, def),
                             symbol: "film.stack", prefKey: ContentRules.rowKey(addon, def), rawCount: raw.count)
        }
    }

    @ViewBuilder
    private func localPage(_ id: String) -> some View {
        switch id {
        case CatalogueRef.continueWatchingID: ContinueWatchingPage()
        case CatalogueRef.recentlyWatchedID: RecentlyWatchedPage()
        default: EmptyView()
        }
    }
}

// MARK: - Collapsing split (poster panel + items)

struct SplitContext {
    /// The items pane has covered the poster panel.
    var collapsed: Bool
    /// How far the split is folded, 0 (poster fully open) to 1 (pane has the whole width).
    var fold: CGFloat
    /// Room the shell reserves at the leading edge when pages draw beneath the sidebar.
    var leadingInset: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat
    /// Vertical points that add up to a full fold.
    var collapseDistance: CGFloat
    /// Bumped by the show-poster button; `PaneScroll` watches it and returns its scroll view to the top.
    var scrollTop: Int
}

/// The wide layout's page: a poster panel on the left, the items on the right. Scrolling the items down (or dragging
/// a row sideways) folds the poster away and gives the pane the whole width; scrolling back to the top, or tapping the
/// edge button, opens it again. The poster is clipped rather than squeezed while it folds.
struct CollapsingSplit<Hero: View, Pane: View>: View {
    var showsHero = true
    var heroFraction: CGFloat = 0.42
    var heroMaxWidth: CGFloat = 506
    var collapseDistance: CGFloat = 260
    /// Room the re-open chevron keeps from the pane's leading edge. A page with a back button passes enough to clear it.
    var heroButtonLeadingExtra: CGFloat = 0
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var pane: (SplitContext) -> Pane

    @Environment(\.pageActive) private var pageActive
    @Environment(\.feedCollapse) private var feedCollapse
    @Environment(\.sidebarInset) private var inset
    @State private var fallback = FeedCollapse()
    @State private var scrollTop = 0

    var body: some View {
        GeometryReader { geo in
            let fc: FeedCollapse = feedCollapse ?? fallback
            let heroFull: CGFloat = min(max(geo.size.width * heroFraction, 290), heroMaxWidth)
            let feedWidth: CGFloat = geo.size.width - (inset + heroFull)
            let tooNarrow: Bool = showsHero && feedWidth < 300
            let fold: CGFloat = tooNarrow ? 1 : (fc.folded ? 1 : 0)
            let heroWidth: CGFloat = inset + heroFull * (1 - fold)
            let ctx = SplitContext(collapsed: fold >= 0.98 || !showsHero,
                                   fold: fold,
                                   leadingInset: inset,
                                   topInset: geo.safeAreaInsets.top,
                                   bottomInset: geo.safeAreaInsets.bottom,
                                   collapseDistance: collapseDistance,
                                   scrollTop: scrollTop)
            HStack(spacing: 0) {
                if showsHero {
                    hero()
                        .frame(width: inset + heroFull, height: geo.size.height, alignment: .leading)
                        .frame(width: heroWidth, height: geo.size.height, alignment: .leading)
                        .clipped()
                        .opacity(min(max(1 - fold * 1.3, 0), 1))
                        .allowsHitTesting(fold <= 0.9)
                        .environment(\.pageActive, pageActive && !ctx.collapsed)
                }
                pane(ctx)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if showsHero && fold > 0.5 && !tooNarrow {
                            // Same line as the back button DetailView draws: max(top, 24) + 16 from the top.
                            showHeroButton(fc, top: max(ctx.topInset, 24) + 16, leading: heroButtonLeadingExtra)
                        }
                    }
                    .environment(\.feedCollapse, fc)
            }
            .animation(.easeInOut(duration: 0.22), value: fold)
            .sensoryFeedback(.selection, trigger: ctx.collapsed)
        }
    }

    private func showHeroButton(_ fc: FeedCollapse, top: CGFloat, leading: CGFloat) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.45)) {
                fc.expand()
                scrollTop += 1
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .pearGlass(in: .circle, interactive: true)
        }
        .buttonStyle(.plain)
        .padding(.leading, leading)
        .padding(.top, top)
        .transition(.opacity)
    }
}

/// The pane's vertical scroll. Its offset feeds `FeedCollapse.vertical`; when it returns to the top the poster opens
/// again. Horizontal scrolling inside the content is never disabled: the rows stay swipeable at all times.
struct PaneScroll<Content: View>: View {
    let ctx: SplitContext
    var refresh: (() async -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.feedCollapse) private var feedCollapse
    @State private var position = ScrollPosition()

    var body: some View {
        let scroll = ScrollView {
            content()
                .padding(.top, ctx.topInset + 18)
                .padding(.bottom, ctx.bottomInset + 40)
                .pointerDragScroll()
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Int.self) { geo in
            FeedCollapse.bucket(max(geo.contentOffset.y + geo.contentInsets.top, 0) / ctx.collapseDistance)
        } action: { _, b in
            feedCollapse?.setVertical(bucket: b)
        }
        .onChange(of: ctx.scrollTop) { _, _ in
            withAnimation(.smooth(duration: 0.45)) { position.scrollTo(edge: .top) }
        }
        if let refresh { scroll.refreshable { await refresh() } } else { scroll }
    }
}

/// Feeds a horizontal row's scroll distance into the pane's fold. It is inert outside the wide layout.
private struct ReportsRowDrag: ViewModifier {
    let id: AnyHashable
    @Environment(\.feedCollapse) private var feedCollapse
    @Environment(\.wideLayout) private var wide

    @ViewBuilder func body(content: Content) -> some View {
        if wide, let fc = feedCollapse {
            content
                .onScrollGeometryChange(for: Int.self) { geo in
                    FeedCollapse.bucket(max(geo.contentOffset.x + geo.contentInsets.leading, 0) / 360)
                } action: { _, b in
                    fc.report(id, bucket: b)
                }
                .onDisappear { fc.forget(id) }
        } else {
            content
        }
    }
}

extension View {
    /// Report this horizontal row's drag to the wide layout's `FeedCollapse`. Does nothing on the phone.
    func reportsRowDrag(id: AnyHashable) -> some View { modifier(ReportsRowDrag(id: id)) }
}

/// Folds the sidebar as a plain vertical scroll view moves, the way `PaneScroll` folds the poster panel. For pages
/// with no poster (grids, lists, settings). It is inert outside the wide layout.
private struct CollapsesSidebarOnScroll: ViewModifier {
    let distance: CGFloat
    @Environment(\.feedCollapse) private var feedCollapse
    @Environment(\.wideLayout) private var wide

    @ViewBuilder func body(content: Content) -> some View {
        if wide, let fc = feedCollapse {
            content
                .onScrollGeometryChange(for: Int.self) { geo in
                    FeedCollapse.bucket(max(geo.contentOffset.y + geo.contentInsets.top, 0) / distance)
                } action: { _, b in
                    fc.setVertical(bucket: b)
                }
        } else {
            content
        }
    }
}

extension View {
    /// Let this vertical scroll view fold the wide layout's sidebar, the same way a poster page's pane does.
    func collapsesSidebarOnScroll(distance: CGFloat = 160) -> some View {
        modifier(CollapsesSidebarOnScroll(distance: distance))
    }
}

/// A page pushed inside a tab or the catalogue, such as a "See all" grid. It owns its fold the way `DetailView` does:
/// registered as `shellNav.activeFold` while it is the page on screen, and cleared when it leaves, so the sidebar goes
/// back to the tab's own fold once it is popped. It is inert outside the wide layout.
struct PushedFoldPage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(ShellNav.self) private var shellNav
    @Environment(\.pageActive) private var pageActive
    @Environment(\.wideLayout) private var wide
    @State private var fold = FeedCollapse()

    var body: some View {
        if wide {
            content()
                .environment(\.feedCollapse, fold)
                .onAppear { if pageActive { shellNav.activeFold = fold } }
                .onDisappear { if shellNav.activeFold === fold { shellNav.activeFold = nil } }
                .onChange(of: pageActive) { _, active in
                    if active {
                        shellNav.activeFold = fold
                    } else if shellNav.activeFold === fold {
                        shellNav.activeFold = nil
                    }
                }
        } else {
            content()
        }
    }
}

// MARK: - Home poster panel

/// Home's big panel: the day's featured titles as tall poster art with the logo, rating, synopsis and a Details
/// button. Rotates by itself (like the phone hero); tap a dot to jump.
struct WideHeroPanel: View {
    let items: [MetaPreview]
    @Binding var tint: Color?
    @Environment(\.pageActive) private var pageActive
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sidebarInset) private var inset
    @Environment(\.feedCollapse) private var fc
    @Environment(ThemeStore.self) private var theme
    @State private var page: String?
    @State private var visible = true
    @State private var expanded = false
    @State private var lastToggle = Date.distantPast

    private static let interval = 8.0
    private var currentID: String { page ?? items.first?.id ?? "" }
    private var index: Int { items.firstIndex(where: { $0.id == currentID }) ?? 0 }
    private var current: MetaPreview? { items.first(where: { $0.id == currentID }) ?? items.first }
    /// On screen, in the foreground, and not hidden behind another page or the sliding pane.
    private var pageRunning: Bool { visible && pageActive && scenePhase == .active && !LayoutState.shared.pagesCovered }
    /// Auto-advance also stops while the synopsis is open.
    private var running: Bool { pageRunning && !expanded }
    private struct AutoKey: Hashable { let page: String; let active: Bool }

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let h: CGFloat = geo.size.height
            let compact: Bool = h < 560
            ZStack(alignment: .bottom) {
                if let item = current {
                    NavigationLink(value: item) {
                        ZStack(alignment: .bottomLeading) {
                            art(item, size: geo.size)
                                .id(currentID)
                                .transition(heroSlide(width: w))
                                .animation(.easeInOut(duration: 0.9), value: currentID)
                            info(item, compact: compact)
                                .id(currentID)
                                .transition(heroSlide(width: w))
                                .animation(.easeInOut(duration: 0.9), value: currentID)
                        }
                        .frame(width: w, height: h)
                        .clipped()
                    }
                    .buttonStyle(.plain)
                } else {
                    skeleton(size: geo.size)
                }
                if items.count > 1 {
                    dots
                        .padding(.leading, inset)
                        .padding(.bottom, 26)
                }
            }
            .frame(width: w, height: h)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: items.map(\.id)) { _, ids in
            if let p = page, !ids.contains(p) { page = ids.first }
        }
        .onChange(of: currentID) { _, _ in expanded = false }
        .task(id: AutoKey(page: currentID, active: running)) {
            guard running, items.count > 1 else { return }
            try? await Task.sleep(for: .seconds(Self.interval))
            guard !Task.isCancelled else { return }
            let next: String = items[(index + 1) % items.count].id
            withAnimation(.easeInOut(duration: 0.9)) { page = next }
        }
        .task(id: currentID) { await updateTint() }
    }

    // MARK: Art

    /// The art slides and fades on item change; the dots and the pane never do.
    private func heroSlide(width: CGFloat) -> AnyTransition {
        let shift: CGFloat = width * 0.1
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: shift)),
                           removal: .opacity.combined(with: .offset(x: -shift)))
    }

    /// Opaque to half the width, then eased out, so the poster has no hard edge against the feed.
    private var rightFade: LinearGradient {
        LinearGradient(stops: [.init(color: .black, location: 0),
                               .init(color: .black, location: 0.5),
                               .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }

    private var bottomFade: LinearGradient {
        LinearGradient.easedFade(start: 0.42, from: 1, to: 0)
    }

    private func art(_ item: MetaPreview, size: CGSize) -> some View {
        let panelW: CGFloat = size.width
        let panelH: CGFloat = size.height
        let overscan: CGFloat = panelH * 0.125
        let artH: CGFloat = panelH * 1.25
        // Parallax used to follow the scroll offset frame by frame, which re-rendered the art on every frame of a
        // scroll. It now shifts once, with the fold, and animates there.
        let parallax: CGFloat = (fc?.folded ?? false) ? overscan : 0
        let y: CGFloat = parallax - overscan
        return ZStack(alignment: .bottom) {
            KenBurns(active: pageRunning, targetScale: 1.1, duration: 18) {
                RotatingArtwork(item: item, kind: .poster, size: 1000)
                    .frame(width: panelW, height: artH)
                    .clipped()
            }
            .frame(width: panelW, height: artH)
            .offset(y: y)
            .frame(width: panelW, height: panelH, alignment: .top)
            .clipped()
            scrim
        }
        .frame(width: panelW, height: panelH)
        .clipped()
        .mask { rightFade }
        .mask { bottomFade }
    }

    private var scrim: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0.5),
                               .init(color: .black.opacity(expanded ? 0.9 : 0.7), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .animation(.easeInOut(duration: 0.25), value: expanded)
    }

    private func skeleton(size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(Color.white.opacity(0.06))
            .frame(width: size.width, height: size.height)
            .mask { rightFade }
            .mask { bottomFade }
            .allowsHitTesting(false)
    }

    // MARK: Info

    private func info(_ item: MetaPreview, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            typePill(item)
            TitleArt(item: item, maxWidth: 420, maxHeight: compact ? 68 : 96,
                     font: .archivo(size: compact ? 32 : 40, weight: .black), tracking: 1)
            ScrollView(.horizontal) {
                InlineRatings(item: item)
                    .pointerDragScroll()
            }
            .scrollIndicators(.hidden)
            synopsis(item)
            detailsButton
        }
        .foregroundStyle(.white)
        .padding(.leading, 30 + inset)
        .padding(.trailing, 40)
        .padding(.bottom, 74)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func typePill(_ item: MetaPreview) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.type == "series" ? "tv" : "film")
                .font(.system(size: 13, weight: .semibold))
            Text(item.typeLabel.uppercased())
                .font(.archivo(size: 12, weight: .bold))
            if let y = item.year {
                Text(String(y))
                    .font(.archivo(size: 13, weight: .semibold))
                    .opacity(0.85)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.18), in: Capsule())
    }

    @ViewBuilder private func synopsis(_ item: MetaPreview) -> some View {
        if let d = item.description, !d.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(d)
                    .font(.archivo(size: 17, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(expanded ? nil : 3)
                    .frame(maxWidth: 620, alignment: .leading)
                if d.count > 160 {
                    Button(action: toggleExpanded) {
                        Text(expanded ? "Less" : "More")
                            .font(.archivo(.subheadline, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    // The panel itself is a NavigationLink; a high priority tap keeps this control from opening it.
                    .highPriorityGesture(TapGesture().onEnded { toggleExpanded() })
                }
            }
        }
    }

    private func toggleExpanded() {
        // The Button and its high priority tap can both report the same press; only the first one toggles.
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.2 else { return }
        lastToggle = now
        withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
    }

    private var detailsButton: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .semibold))
            Text("Details")
                .font(.archivo(.subheadline, weight: .semibold))
        }
        .foregroundStyle(theme.onAccent)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(theme.accent, in: Capsule())
    }

    // MARK: Dots

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                let on: Bool = i == index
                Button {
                    withAnimation(.easeInOut(duration: 0.9)) { page = it.id }
                } label: {
                    Capsule()
                        .fill(.white.opacity(on ? 1 : 0.4))
                        .frame(width: on ? 22 : 6, height: 5)
                        .frame(height: 20, alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Featured \(i + 1) of \(items.count)")
            }
        }
        .animation(.easeInOut(duration: 0.4), value: index)
    }

    @MainActor private func updateTint() async {
        guard let item = current,
              let url = ArtworkRotation.shared.poster(for: item, longestEdgePixels: 1000).url,
              let c = await ImagePipeline.shared.averageColor(for: url), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.9)) { tint = Color(uiColor: c) }
    }
}
