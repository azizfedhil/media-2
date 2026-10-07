import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AddonStore.self) private var store
    @Environment(SimklStore.self) private var simkl
    @Environment(ThemeStore.self) private var theme
    @Environment(ProfileStore.self) private var profiles
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library
    @Environment(LibraryPrefs.self) private var libraryPrefs
    @Environment(WatchLog.self) private var watchLog
    @Environment(PinnedSources.self) private var pins
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("tvdb.key") private var tvdbKey = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("ui.networkBadges") private var networkBadges = true
    @AppStorage("ui.titleLogos") private var titleLogos = true
    @AppStorage("player.glass") private var glass = true
    @AppStorage("player.autoplayNext") private var autoplayNext = true
    @AppStorage(PiPController.enabledKey) private var pipEnabled = true
    @AppStorage("skip.enabled") private var skipEnabled = true
    @AppStorage("skip.fallbackSeconds") private var fallbackSkip = 85
    @AppStorage(P2PSettings.enabledKey) private var p2pEnabled = false
    @AppStorage(P2PSettings.wifiOnlyKey) private var p2pWifiOnly = true
    @State private var confirmP2P = false
    @AppStorage("sub.lang") private var subLang = "off"
    @State private var includeData = false
    @State private var exportDoc: BackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var backupNote: String?

    private var connected: Int {
        [!tmdbKey.isEmpty, !tvdbKey.isEmpty, !mdbKey.isEmpty, simkl.isConnected].filter { $0 }.count
    }

    private var addonSummary: String {
        if store.addons.isEmpty { return "None" }
        let on = store.addons.filter { store.isEnabled($0) }.count
        return on == store.addons.count ? "\(on) installed" : "\(on) of \(store.addons.count) on"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { IntegrationsView() } label: {
                        HStack {
                            Label("Integrations", systemImage: "puzzlepiece.extension.fill")
                            Spacer()
                            Text("\(connected) of 4 set up").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("TMDB, TheTVDB, MDBList and Simkl: API keys, logins and metadata sources.")
                }

                Section {
                    NavigationLink { AddonsSettingsView() } label: {
                        HStack {
                            Label("Add-ons", systemImage: "square.stack.3d.up.fill")
                            Spacer()
                            Text(addonSummary).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Add, reorder, switch off and configure your Stremio add-ons.")
                }

                Section {
                    LibrarySourceControls()
                } header: { Text("Library · \(profiles.active.name)") } footer: {
                    Text("Chosen per profile. A library on this device keeps its own watch history and watch time and never contacts Simkl. Syncing merges both libraries without deleting anything on either side.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Accent colour").font(.subheadline.weight(.medium))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 12)], spacing: 12) {
                            Button { theme.setAccent(hex: Theme.systemHex) } label: {
                                Circle().fill(.black).frame(width: 36, height: 36)
                                    .overlay {
                                        Circle().fill(.white).frame(width: 36, height: 36)
                                            .mask(HStack(spacing: 0) { Rectangle(); Color.clear })
                                    }
                                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                                    .overlay {
                                        if theme.isSystem {
                                            Image(systemName: "checkmark").font(.footnote.weight(.black))
                                                .foregroundStyle(Color(white: 0.5))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("System (no accent)")
                            ForEach(Theme.presets, id: \.hex) { p in
                                Button { theme.setAccent(hex: p.hex) } label: {
                                    Circle().fill(Color(hex: p.hex) ?? .gray).frame(width: 36, height: 36)
                                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                                        .overlay {
                                            if theme.hex.uppercased() == p.hex {
                                                Image(systemName: "checkmark").font(.footnote.weight(.black))
                                                    .foregroundStyle((Color(hex: p.hex) ?? .gray).contrastingForeground)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(p.name)
                            }
                        }
                        ColorPicker("Custom colour", selection: Binding(get: { theme.accent },
                                                                          set: { theme.setAccent(hex: $0.hexString) }),
                                    supportsOpacity: false)
                    }
                    .padding(.vertical, 4)
                    Toggle("Network icons on posters", isOn: $networkBadges)
                    Toggle("Logos instead of title text", isOn: $titleLogos)
                } header: { Text("Appearance") } footer: {
                    Text("Network icons need a TMDB key and make one small request per visible poster. Logos come from TMDB, TheTVDB and Metahub and are cached after the first lookup.")
                }

                Section {
                    NavigationLink {
                        SubtitleSettingsView()
                    } label: {
                        HStack {
                            Label("Subtitles", systemImage: "captions.bubble")
                            Spacer()
                            Text(subLang == "off" ? "Off" : (SubLanguages.all.first { $0.code == subLang }?.name ?? subLang))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Liquid Glass controls", isOn: $glass)
                    Toggle("Autoplay next episode", isOn: $autoplayNext)
                    Toggle("Picture in Picture", isOn: $pipEnabled)
                    Toggle("Skip intro / recap / credits", isOn: $skipEnabled)
                    if skipEnabled {
                        Stepper(fallbackSkip == 0 ? "Manual skip button: off" : "Manual skip button: \(fallbackSkip) s",
                                value: $fallbackSkip, in: 0...180, step: 5)
                    }
                } header: { Text("Playback") } footer: {
                    Text("Skip buttons use community timestamps from TheIntroDB. When a show has none, the manual button jumps ahead by the chosen time. Set it to 0 to hide it. Turn Liquid Glass off if playback ever feels heavy on an older device. Turning Picture in Picture off removes its button and stops videos from floating when you leave the app.")
                }

                Section {
                    Toggle("Peer-to-peer streams", isOn: Binding(
                        get: { p2pEnabled },
                        set: { on in if on { confirmP2P = true } else { p2pEnabled = false } }))
                        .alert("Enable peer-to-peer?", isPresented: $confirmP2P) {
                            Button("Enable") { p2pEnabled = true }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Torrent streams connect directly to other peers, so your IP address is visible to them. A VPN is recommended. Nothing runs until you play a P2P stream.")
                        }
                    if p2pEnabled { Toggle("Wi-Fi only", isOn: $p2pWifiOnly) }
                } header: { Text("Peer-to-peer") } footer: {
                    Text("Off by default. When off, torrent sources are hidden and nothing P2P is started. Debrid and direct links are never affected.")
                }
                .onChange(of: p2pEnabled) { _, on in if !on { P2PManager.shared.stop(); P2PNetwork.shared.stop() } }

                Section {
                    Toggle("Include watch history & library", isOn: $includeData)
                    Button { export() } label: { Label("Export settings", systemImage: "square.and.arrow.up") }
                    Button { showImporter = true } label: { Label("Import settings", systemImage: "square.and.arrow.down") }
                    if let backupNote { Text(backupNote).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Backup") } footer: {
                    Text("The file contains your API keys and add-on URLs, so keep it private. The Simkl login isn't included; reconnect it after importing.")
                }
            }
            .fileExporter(isPresented: $showExporter, document: exportDoc ?? BackupDocument(),
                          contentType: .propertyList, defaultFilename: "Pear-Settings") { r in
                if case .failure = r { backupNote = "Export failed." } else { backupNote = "Settings exported." }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.propertyList]) { r in
                importSettings(r)
            }
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

    private func export() {
        do {
            exportDoc = BackupDocument(data: try SettingsBackup.export(includeData: includeData))
            showExporter = true
        } catch { backupNote = "Export failed." }
    }

    private func importSettings(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let n = try SettingsBackup.restore(try Data(contentsOf: url))
            theme.reload(); profiles.reload(); history.reload(); library.reload(); watchLog.reload(); pins.reload(); libraryPrefs.reload()
            Task { await store.reloadFromDefaults() }
            backupNote = "Imported \(n) settings."
        } catch {
            backupNote = (error as? LocalizedError)?.errorDescription ?? "Import failed."
        }
    }
}
