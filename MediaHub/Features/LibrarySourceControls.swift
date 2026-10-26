import SwiftUI

/// The profile's library switch: this device, Pear.pair or Simkl, plus syncing. Used on the profile page and in Settings.
/// Rows only, so it works inside a Form section or a card.
struct LibrarySourceControls: View {
    @Environment(LibraryPrefs.self) private var prefs
    @Environment(SimklStore.self) private var simkl
    @Environment(LocalLibrary.self) private var library
    @Environment(WatchHistory.self) private var history

    var body: some View {
        let connected = simkl.isConnected
        let source = prefs.source(simkl)
        Picker("Library", selection: Binding(get: { source }, set: { choose($0) })) {
            Text("This device").tag(LibrarySource.local)
            Text("Pear.pair").tag(LibrarySource.pair)
            Text("Simkl").tag(LibrarySource.simkl)
        }
        .pickerStyle(.segmented)

        if source == .pair {
            // Kept in step across this account's devices over Pear.pair. Simkl is only imported from, one way.
            Text(PairSync.shared.isSignedIn
                 ? "Your library is kept in step with your other devices over Pear.pair."
                 : "Sign in to Pear.pair to keep this library in step with your other devices.")
                .font(.archivo(.footnote)).foregroundStyle(.secondary)

            if connected {
                Text("Import adds Simkl's titles that are missing here. It never sends anything to Simkl and never removes anything here.")
                    .font(.archivo(.footnote)).foregroundStyle(.secondary)

                Button {
                    Task { await prefs.importFromSimkl(simkl: simkl, library: library, history: history, force: true) }
                } label: {
                    HStack {
                        Label(prefs.isSyncing ? "Importing…" : "Import from Simkl", systemImage: "square.and.arrow.down")
                        Spacer()
                        if prefs.isSyncing { ProgressView() }
                    }
                }
                .disabled(prefs.isSyncing)

                if let report = prefs.report {
                    Text(report).font(.archivo(.footnote)).foregroundStyle(.secondary)
                }
            } else {
                Text("Connect Simkl in Integrations to import its lists.")
                    .font(.archivo(.footnote)).foregroundStyle(.secondary)
            }
        } else if connected {
            let expl = source == .local
                ? "Your own library and watch tracking on this device. Nothing is sent to Simkl."
                : "Simkl's lists are your library, and what you watch is scrobbled to Simkl."
            Text(expl)
                .font(.archivo(.footnote)).foregroundStyle(.secondary)

            Toggle("Keep in sync automatically", isOn: Binding(get: { prefs.autoSync }, set: { prefs.setAutoSync($0) }))

            Button { Task { await prefs.sync(simkl: simkl, library: library, history: history, force: true) } } label: {
                HStack {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if prefs.isSyncing { ProgressView() }
                }
            }
            .disabled(prefs.isSyncing)

            if let report = prefs.report {
                Text(report).font(.archivo(.footnote)).foregroundStyle(.secondary)
            } else if let last = prefs.lastSync {
                Text("Last synced \(last.formatted(.relative(presentation: .named)))").font(.archivo(.footnote)).foregroundStyle(.secondary)
            }
        } else {
            Text("Your library stays on this device. It is not synced to other devices. Connect Simkl in Integrations to use it as your library or to sync with it.")
                .font(.archivo(.footnote)).foregroundStyle(.secondary)
        }
    }

    private func choose(_ s: LibrarySource) {
        // Simkl needs a connection. Without one the picker snaps back to the current choice.
        if s == .simkl && !simkl.isConnected { return }
        withAnimation(.snappy(duration: 0.3)) { prefs.choose(s) }
        // Switching to Simkl: make sure its lists are loaded (a no-op if they were fetched in the last 15 minutes).
        if s == .simkl { Task { await simkl.sync() } }
        // Switching to Pear.pair: fetch what the other devices hold now, rather than at the next timed sync.
        if s == .pair { PairSync.shared.syncNow() }
    }
}
