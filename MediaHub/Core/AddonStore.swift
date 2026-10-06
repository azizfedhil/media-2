import SwiftUI
import Observation

@MainActor @Observable
final class AddonStore {
    /// Every installed add-on, in the user's order (the order is saved).
    private(set) var addons: [Addon] = []
    /// Ids of installed add-ons the user switched off. They stay installed and keep their place in the
    /// order, but are skipped everywhere add-ons are used (Home, search, sources, downloads).
    private(set) var disabledIDs: Set<String> = []
    /// Add-ons currently in use: installed and switched on, in the user's order.
    var enabledAddons: [Addon] { addons.filter { !disabledIDs.contains($0.id) } }
    /// Bumps after a reload so Home refetches catalogs even though the add-on ids are unchanged.
    private(set) var revision = 0
    private let key = "addon.manifestURLs"
    private static let disabledKey = "addon.disabled"
    /// Saved add-on URLs that couldn't be fetched at launch (offline, server down). They aren't shown, but
    /// they are written back on every save so reordering or adding an add-on never drops them from storage.
    @ObservationIgnored private var unreachable: [String] = []
    // Public metadata-only add-on, so Home isn't empty on first launch.
    private static let defaults = ["https://v3-cinemeta.strem.io/manifest.json"]

    init() {
        disabledIDs = Self.loadDisabled()
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? Self.defaults
        Task { await restore(saved) }
    }

    private static func loadDisabled() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
    }

    func isEnabled(_ addon: Addon) -> Bool { !disabledIDs.contains(addon.id) }

    /// Switches an add-on on or off without uninstalling it.
    func setEnabled(_ addon: Addon, _ on: Bool) {
        if on { disabledIDs.remove(addon.id) } else { disabledIDs.insert(addon.id) }
        persistDisabled()
    }

    /// Reorders the installed add-ons (drag in Settings -> Add-ons).
    func move(from source: IndexSet, to destination: Int) {
        addons.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func add(_ input: String) async throws {
        let url = try Addon.normalize(input)
        guard !addons.contains(where: { $0.manifestURL == url }) else { return }
        let manifest = try await AddonClient.shared.manifest(at: url)
        // Added by hand now, so it's no longer an "unreachable" leftover (avoids saving it twice).
        unreachable.removeAll { $0 == url.absoluteString }
        addons.append(Addon(manifestURL: url, manifest: manifest))
        persist()
    }

    /// Re-fetches one add-on's manifest (bypassing the HTTP cache) and refreshes its catalogs.
    func reload(_ addon: Addon) async throws {
        await AddonClient.shared.clearCache()
        let m = try await AddonClient.shared.manifest(at: addon.manifestURL, fresh: true)
        guard let i = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        addons[i] = Addon(manifestURL: addon.manifestURL, manifest: m)
        revision += 1
    }

    /// Reloads every add-on. Returns how many failed (those keep their old manifest).
    func reloadAll() async -> Int {
        await AddonClient.shared.clearCache()
        var failed = 0
        for a in addons {
            if let m = try? await AddonClient.shared.manifest(at: a.manifestURL, fresh: true),
               let i = addons.firstIndex(where: { $0.id == a.id }) {
                addons[i] = Addon(manifestURL: a.manifestURL, manifest: m)
            } else { failed += 1 }
        }
        revision += 1
        return failed
    }

    /// Re-reads the saved add-on list (after a settings import).
    func reloadFromDefaults() async {
        disabledIDs = Self.loadDisabled()
        await restore(UserDefaults.standard.stringArray(forKey: key) ?? Self.defaults)
        revision += 1
    }

    func remove(at offsets: IndexSet) {
        let gone = offsets.map { addons[$0].id }
        addons.remove(atOffsets: offsets)
        disabledIDs.subtract(gone)
        persist()
        persistDisabled()
    }

    // TODO: move to Keychain — debrid add-on URLs embed API keys.
    private func persist() {
        UserDefaults.standard.set(addons.map(\.manifestURL.absoluteString) + unreachable, forKey: key)
    }

    private func persistDisabled() {
        UserDefaults.standard.set(disabledIDs.sorted(), forKey: Self.disabledKey)
    }

    private func restore(_ urls: [String]) async {
        var found: [Int: Addon] = [:]
        await withTaskGroup(of: (Int, Addon?).self) { group in
            for (i, s) in urls.enumerated() {
                group.addTask {
                    guard let url = try? Addon.normalize(s),
                          let m = try? await AddonClient.shared.manifest(at: url) else { return (i, nil) }
                    return (i, Addon(manifestURL: url, manifest: m))
                }
            }
            for await (i, a) in group { found[i] = a }
        }
        addons = found.keys.sorted().compactMap { found[$0] }
        unreachable = urls.indices.filter { found[$0] == nil }.map { urls[$0] }
    }
}
