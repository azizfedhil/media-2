import SwiftUI

struct SettingsView: View {
    @Environment(AddonStore.self) private var store
    @Environment(SimklStore.self) private var simkl
    @Environment(ProfileStore.self) private var profiles
    @Environment(ContentPrefs.self) private var contentPrefs
    @Environment(ShellNav.self) private var shellNav
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("tvdb.key") private var tvdbKey = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage(P2PSettings.enabledKey) private var p2pEnabled = false

    private var connected: Int {
        [!tmdbKey.isEmpty || TMDBClient.hasProxy, !tvdbKey.isEmpty, !mdbKey.isEmpty, simkl.isConnected].filter { $0 }.count
    }

    private var addonSummary: String {
        if store.addons.isEmpty { return "None" }
        let on = store.addons.filter { store.isEnabled($0) }.count
        return on == store.addons.count ? "\(on) installed" : "\(on) of \(store.addons.count) on"
    }

    private var contentSummary: String {
        let n = contentPrefs.rules.hiddenCategories.count + contentPrefs.rules.hiddenRows.count
        return n == 0 ? "Everything shown" : "\(n) hidden"
    }

    /// One row of the menu: icon + title on the left, a short summary on the right.
    private func row(_ title: String, _ symbol: String, _ summary: String? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let summary { Text(summary).font(.archivo(.footnote)).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        NavigationStack(path: shellNav.binding(for: .settings)) {
            Form {
                Section {
                    NavigationLink { PairSettingsView() } label: {
                        row("Pear.pair", "arrow.triangle.2.circlepath", PairSync.shared.isSignedIn ? "On" : "Off")
                    }
                    NavigationLink { PartyView() } label: { row("Watch party", "person.2") }
                } header: { Text("Sync & sharing") } footer: {
                    Text("Pear.pair keeps your profiles, history and library in step across devices. Watch party plays the same title together, each person with their own add-ons.")
                }

                Section {
                    NavigationLink { IntegrationsView() } label: {
                        row("Integrations", "puzzlepiece.extension.fill", "\(connected) of 4 set up")
                    }
                    NavigationLink { AddonsSettingsView() } label: {
                        row("Add-ons", "square.stack.3d.up.fill", addonSummary)
                    }
                    NavigationLink { ContentSettingsView() } label: {
                        row("Content & catalogues", "line.3.horizontal.decrease.circle.fill", contentSummary)
                    }
                    NavigationLink { LibrarySettingsView() } label: {
                        row("Library", "books.vertical.fill", simkl.name(for: profiles.active))
                    }
                } header: { Text("Sources & content") } footer: {
                    Text("API keys and logins, your Stremio add-ons, what shows on Home, and where your library lives. Content and Library are chosen per profile.")
                }

                Section {
                    NavigationLink { AppearanceSettingsView() } label: { row("Appearance", "paintpalette.fill") }
                    NavigationLink { PlaybackSettingsView() } label: { row("Playback", "play.rectangle.fill") }
                    NavigationLink { P2PSettingsView() } label: {
                        row("Peer-to-peer", "antenna.radiowaves.left.and.right", p2pEnabled ? "On" : "Off")
                    }
                } header: { Text("App") }

                Section {
                    NavigationLink { BackupSettingsView() } label: { row("Backup", "externaldrive.fill") }
                    NavigationLink { AboutView() } label: { row("About", "info.circle.fill", AboutView.versionString) }
                } header: { Text("Data & info") }
            }
            .collapsesSidebarOnScroll()
            .shellDestinations()
            .navigationTitle("Settings")
            .profileToolbar()
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
    }
}
