import SwiftUI

// MARK: - Items

/// Everything that can sit in the player's controls pill. Declaration order is the on-screen order.
enum PillItem: String, CaseIterable, Identifiable {
    case speed, episodes, sources, volume, pip, subtitles, audio, next

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: "Speed"
        case .episodes: "Episodes"
        case .sources: "Sources"
        case .volume: "Volume"
        case .pip: "Picture in Picture"
        case .subtitles: "Subtitles"
        case .audio: "Audio track"
        case .next: "Next episode"
        }
    }

    var symbol: String {
        switch self {
        case .speed: "speedometer"
        case .episodes: "list.bullet"
        case .sources: "rectangle.stack"
        case .volume: "speaker.wave.2"
        case .pip: "pip.enter"
        case .subtitles: "captions.bubble"
        case .audio: "waveform"
        case .next: "forward.end.fill"
        }
    }

    // MARK: Which items stay visible when the pill is folded

    /// `@AppStorage` key: the pinned items as comma-separated raw values.
    static let storageKey = "player.pillPinned"
    /// The pill folds when it has more items than this, and at most this many can be pinned.
    static let maxPinned = 4
    /// What stays visible out of the box.
    static let defaultPinned: Set<PillItem> = [.volume, .subtitles, .speed, .pip]
    static let defaultRaw = encode(defaultPinned)

    /// Unknown names are ignored, anything past `maxPinned` is dropped, and an empty list means the default.
    static func decode(_ raw: String) -> Set<PillItem> {
        let found = raw.split(separator: ",").compactMap { PillItem(rawValue: String($0)) }
        let set = Set(found.prefix(maxPinned))
        return set.isEmpty ? defaultPinned : set
    }

    static func encode(_ items: Set<PillItem>) -> String {
        allCases.filter { items.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - Settings screen

/// Settings -> Playback -> Player controls: which buttons of the player's pill stay visible while it is folded.
/// The pill only folds when it has more than four buttons; the rest sit behind its chevron.
struct PlayerControlsSettingsView: View {
    @AppStorage(PillItem.storageKey) private var raw = PillItem.defaultRaw

    private var pinned: Set<PillItem> { PillItem.decode(raw) }

    var body: some View {
        Form {
            Section {
                preview
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                ForEach(PillItem.allCases) { item in
                    Toggle(isOn: binding(item)) {
                        Label(item.title, systemImage: item.symbol)
                    }
                    .disabled(isLocked(item))
                }
            } header: {
                Text("Always visible · \(pinned.count) of \(PillItem.maxPinned)")
            } footer: {
                Text("These stay in the pill while it is folded. Everything else slides out to the left when you tap the arrow, and folds back after 5 seconds. A button only shows when it applies: Episodes for shows, Next for series, Audio when there is more than one track.")
            }

            Section {
                Button("Reset to default") { raw = PillItem.defaultRaw }
                    .disabled(pinned == PillItem.defaultPinned)
            }
        }
        .navigationTitle("Player controls")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The pill as it will look when folded.
    private var preview: some View {
        HStack(spacing: 2) {
            Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40)
            ForEach(PillItem.allCases.filter { pinned.contains($0) }) { item in
                Image(systemName: item.symbol).font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
            }
        }
        .foregroundStyle(.white)
        .padding(4)
        .background(Color.black.opacity(0.75), in: Capsule())
        .animation(.snappy(duration: 0.2), value: raw)
    }

    private func binding(_ item: PillItem) -> Binding<Bool> {
        Binding(get: { pinned.contains(item) },
                set: { on in
                    var next = pinned
                    if on { next.insert(item) } else { next.remove(item) }
                    raw = PillItem.encode(next)
                })
    }

    /// Full: nothing more can be pinned until something is unpinned. Last one: at least one stays.
    private func isLocked(_ item: PillItem) -> Bool {
        pinned.contains(item) ? pinned.count <= 1 : pinned.count >= PillItem.maxPinned
    }
}
