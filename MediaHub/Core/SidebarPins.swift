import Foundation
import Observation

/// The titles pinned to the sidebar, per profile. The newest pin is last.
/// A pin that cannot be read is skipped, never thrown.
@MainActor @Observable
final class SidebarPins {
    static let limit = 30

    private(set) var items: [MetaPreview] = []
    @ObservationIgnored private var profileID = ProfileKeys.activeID
    private var storeKey: String { ProfileKeys.scoped("sidebar.pins", profileID) }

    init() { items = Self.read(storeKey) }

    func isPinned(_ id: String) -> Bool { items.contains { $0.id == id } }

    func pin(_ item: MetaPreview) {
        guard !isPinned(item.id), items.count < Self.limit else { return }
        items.append(item)
        persist()
    }

    func unpin(_ id: String) {
        guard isPinned(id) else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    func toggle(_ item: MetaPreview) {
        if isPinned(item.id) { unpin(item.id) } else { pin(item) }
    }

    /// Switches to another profile's pins. No-op when it is already loaded.
    func load(profile id: String) {
        guard id != profileID else { return }
        profileID = id
        items = Self.read(storeKey)
    }

    /// Re-reads the active profile's pins from storage (after a settings import).
    func reload() {
        profileID = ProfileKeys.activeID
        items = Self.read(storeKey)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    private static func read(_ key: String) -> [MetaPreview] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([FailableMetaPreview].self, from: d) else { return [] }
        return saved.compactMap(\.value)
    }
}

/// Decodes one pin on its own, so a single bad entry doesn't drop the rest of the list.
private struct FailableMetaPreview: Decodable {
    let value: MetaPreview?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(MetaPreview.self)
    }
}
