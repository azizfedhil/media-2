import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer

// Brightness (left) and volume (right) swipes for the player.
//
// Design notes, because this runs over live video and must cost nothing while idle:
// - The drag is attached to the player's existing background layer, so SwiftUI's own hit-testing keeps it away from
//   the controls, the seek bar and the open panels: only touches on empty video ever reach it.
// - While dragging, nothing in SwiftUI changes. The controller is a plain object (not Observable), it writes the
//   level straight to UIKit, and the HUD is a small UIKit view, so the player's body is never re-evaluated by a swipe.
// - No timers run during a swipe. One short sleep is scheduled when the finger lifts, to fade the HUD out.
// - Nothing stays resident: the HUD and the volume view are created when a swipe starts and removed after the fade.

/// Which level a swipe is adjusting.
enum PlayerLevelKind { case brightness, volume }

@MainActor
final class LevelGestureController {
    /// Movement before the drag is recognised at all. Larger than a tap's tolerance, so taps are never mistaken for it.
    static let minimumDistance: CGFloat = 16
    /// The swipe must be at least this many times taller than it is wide at the moment it is recognised.
    private static let verticalBias: CGFloat = 1.5
    /// Left 40% = brightness, right 40% = volume, the middle 20% does nothing.
    private static let sideZone: CGFloat = 0.4
    /// A swipe covering this share of the video's height sweeps the whole 0...1 range.
    private static let travel: CGFloat = 0.8
    private static let hideDelay: Duration = .milliseconds(900)

    /// Size of the gesture area. Written by `onGeometryChange` on layout changes only; plain property, no invalidation.
    var size: CGSize = .zero

    private enum Phase { case idle, rejected, active }

    private weak var host: UIView?
    private weak var screen: UIScreen?
    private weak var slider: UISlider?
    private var hud: LevelHUD?
    private var volumeView: MPVolumeView?
    private var hideTask: Task<Void, Never>?

    // Current swipe
    private var phase: Phase = .idle
    private var sessionStart: CGPoint?
    private var kind: PlayerLevelKind = .brightness
    private var startLevel: CGFloat = 0
    private var anchorY: CGFloat = 0
    private var lastApplied: CGFloat = 0

    // Brightness is system-wide, so the player gives it back when it closes.
    private var originalBrightness: CGFloat?
    private var lastWrittenBrightness: CGFloat?
    /// True while the original brightness is back in place because the app is in the background.
    private var brightnessSuspended = false
    /// Registered only while a brightness override is outstanding; removed again when it is given back.
    private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: Lifecycle

    /// The invisible, non-interactive view that carries the HUD (and, while needed, the volume view).
    func attach(to view: UIView) {
        if host !== view { removeTransients() }
        host = view
    }

    /// Player closing, or the setting switched off: put brightness back and remove everything this added.
    func finish() {
        hideTask?.cancel(); hideTask = nil
        phase = .idle; sessionStart = nil
        restoreBrightness()
        removeTransients()
    }

    // MARK: Gesture events

    /// Called for every drag update. The first call of a swipe decides whether it is ours at all.
    func changed(_ v: DragGesture.Value, canStart: () -> Bool) {
        // A cancelled drag never reports its end; a new start point means a new swipe.
        if sessionStart != v.startLocation { sessionStart = v.startLocation; phase = .idle }
        switch phase {
        case .rejected: return
        case .idle:
            guard begin(v, canStart: canStart) else { phase = .rejected; return }
            phase = .active
        case .active: break
        }
        update(v)
    }

    /// Finger lifted or the drag was cancelled.
    func ended() {
        sessionStart = nil
        let wasActive = phase == .active
        phase = .idle
        if wasActive { scheduleHide() }
    }

    // MARK: Swipe

    private func begin(_ v: DragGesture.Value, canStart: () -> Bool) -> Bool {
        let t = v.translation
        guard abs(t.height) >= Self.verticalBias * abs(t.width),      // clearly vertical
              size.width > 0, size.height > 0, host != nil, canStart() else { return false }
        let x = v.startLocation.x / size.width
        let k: PlayerLevelKind
        if x < Self.sideZone { k = .brightness }
        else if x > 1 - Self.sideZone { k = .volume }
        else { return false }
        guard let base = prepare(k) else { return false }
        kind = k
        startLevel = base
        lastApplied = base
        anchorY = t.height               // the recognition distance is not counted, so the level never jumps
        presentHUD(level: base)
        return true
    }

    private func update(_ v: DragGesture.Value) {
        let level = min(max(startLevel + (anchorY - v.translation.height) / (size.height * Self.travel), 0), 1)
        hud?.update(level: level, kind: kind)
        // The system only needs a new value every couple of percent; the HUD above follows the finger exactly.
        let step: CGFloat = kind == .brightness ? 0.01 : 0.02
        guard level != lastApplied, abs(level - lastApplied) >= step || level == 0 || level == 1 else { return }
        switch kind {
        case .brightness:
            guard let screen else { return }
            screen.brightness = level
            lastWrittenBrightness = level
        case .volume:
            guard let slider = volumeSlider() else { return }      // not ready yet: retried on the next update
            slider.value = Float(level)
        }
        lastApplied = level
    }

    /// Reads the starting level and gets whatever is needed to change it. nil = this swipe can't adjust that level.
    private func prepare(_ kind: PlayerLevelKind) -> CGFloat? {
        switch kind {
        case .brightness:
            guard let s = host?.window?.windowScene?.screen else { return nil }
            screen = s
            // New baseline unless the screen is still where this player left it: a change made in Control Center wins.
            if originalBrightness == nil || (lastWrittenBrightness.map { abs(s.brightness - $0) >= 0.02 } ?? true) {
                originalBrightness = s.brightness
            }
            observeLifecycle()
            return s.brightness
        case .volume:
            _ = volumeSlider()          // created now so it has settled by the time the first change is written
            // Read-only: no category, mode or activation is touched, so the engine's session is left exactly as it is.
            return CGFloat(AVAudioSession.sharedInstance().outputVolume)
        }
    }

    // MARK: Brightness

    /// Only if the screen is still at the value this player set: a change made meanwhile (Control Center) wins.
    private func restoreBrightness() {
        if let original = originalBrightness, let written = lastWrittenBrightness,
           let screen, abs(screen.brightness - written) < 0.02 {
            screen.brightness = original
        }
        forgetBrightness()
    }

    /// Stops tracking a brightness override (given back, or superseded by the user) and drops its observers.
    private func forgetBrightness() {
        originalBrightness = nil; lastWrittenBrightness = nil
        brightnessSuspended = false
        for o in lifecycleObservers { NotificationCenter.default.removeObserver(o) }
        lifecycleObservers = []
    }

    /// Brightness is a system setting, so it must not stay changed on the Home Screen while the app is in the
    /// background (audio / PiP can keep the player alive there). Background and foreground are the only events used:
    /// pulling down Control Center or a notification doesn't trigger them.
    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        lifecycleObservers = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendBrightness() }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeBrightness() }
            },
        ]
    }

    private func suspendBrightness() {
        guard let original = originalBrightness, let written = lastWrittenBrightness, let screen,
              abs(screen.brightness - written) < 0.02 else { return }
        screen.brightness = original
        brightnessSuspended = true
    }

    private func resumeBrightness() {
        guard brightnessSuspended else { return }
        brightnessSuspended = false
        guard let original = originalBrightness, let written = lastWrittenBrightness, let screen else { return }
        if abs(screen.brightness - original) < 0.02 { screen.brightness = written }
        else { forgetBrightness() }           // changed by the user in the meantime: keep theirs, stop tracking
    }

    // MARK: Volume

    /// The system volume can only be set through MPVolumeView's slider. While it is in the view tree the system's
    /// own volume pop-up is suppressed, so it is added when a volume swipe starts and removed after the HUD fades.
    private func volumeSlider() -> UISlider? {
        if let slider { return slider }
        guard let host else { return nil }
        if volumeView == nil {
            let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 120, height: 40))     // off screen
            v.isUserInteractionEnabled = false
            v.isAccessibilityElement = false
            v.accessibilityElementsHidden = true
            host.addSubview(v)
            v.layoutIfNeeded()
            volumeView = v
        }
        slider = volumeView.flatMap { Self.findSlider(in: $0) }
        return slider
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        for sub in view.subviews {
            if let s = sub as? UISlider { return s }
            if let s = findSlider(in: sub) { return s }
        }
        return nil
    }

    // MARK: HUD

    private func presentHUD(level: CGFloat) {
        hideTask?.cancel(); hideTask = nil
        guard let host else { return }
        let view: LevelHUD
        if let existing = hud { view = existing }
        else {
            view = LevelHUD(frame: .zero)
            view.alpha = 0
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor, constant: 18),   // same spot as the player's toast
            ])
            hud = view
        }
        view.update(level: level, kind: kind)
        view.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.12) { view.alpha = 1 }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard phase != .active, let hud else { return }
        UIView.animate(withDuration: 0.2, animations: { hud.alpha = 0 }, completion: { [weak self] finished in
            // Not finished = a new swipe took over the HUD mid-fade.
            guard finished, let self, self.phase != .active else { return }
            self.removeTransients()
        })
    }

    private func removeTransients() {
        hud?.removeFromSuperview(); hud = nil
        volumeView?.removeFromSuperview(); volumeView = nil
        slider = nil
    }
}

// MARK: - HUD view

/// Flat translucent capsule (same look as the player's toast and its flat, non-glass controls): icon + level bar.
/// Plain UIKit so a swipe updates it without touching SwiftUI.
private final class LevelHUD: UIView {
    private static let trackWidth: CGFloat = 120
    private static let trackHeight: CGFloat = 5
    private let icon = UIImageView()
    private let fill = UIView()
    private var symbol = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = UIColor.black.withAlphaComponent(0.78)
        layer.cornerCurve = .continuous

        icon.tintColor = .white
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)

        let track = UIView()
        track.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        track.layer.cornerRadius = Self.trackHeight / 2
        track.clipsToBounds = true
        fill.backgroundColor = .white
        fill.layer.cornerRadius = Self.trackHeight / 2
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: Self.trackHeight)
        track.addSubview(fill)

        let row = UIStackView(arrangedSubviews: [icon, track])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            icon.widthAnchor.constraint(equalToConstant: 24),      // fixed, so the bar doesn't shift between symbols
            icon.heightAnchor.constraint(equalToConstant: 20),
            track.widthAnchor.constraint(equalToConstant: Self.trackWidth),
            track.heightAnchor.constraint(equalToConstant: Self.trackHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func update(level: CGFloat, kind: PlayerLevelKind) {
        let name = Self.symbol(for: kind, level: level)
        if name != symbol { symbol = name; icon.image = UIImage(systemName: name) }
        fill.frame.size.width = Self.trackWidth * level
    }

    private static func symbol(for kind: PlayerLevelKind, level: CGFloat) -> String {
        switch kind {
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if level < 0.01 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}

// MARK: - SwiftUI glue

/// Empty, non-interactive UIKit view that the controller hangs the HUD on. Only in the tree while the setting is on.
struct LevelHUDHost: UIViewRepresentable {
    let controller: LevelGestureController

    @MainActor final class Coordinator {
        let controller: LevelGestureController
        init(_ controller: LevelGestureController) { self.controller = controller }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.controller.finish()
    }
}

private struct LevelGestureModifier: ViewModifier {
    let enabled: Bool
    let controller: LevelGestureController
    let canStart: () -> Bool
    /// Only used to learn when a drag ends *or is cancelled*. It changes twice per swipe, never per frame, and only
    /// this tiny modifier is re-evaluated, not the player.
    @GestureState private var dragging = false

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGSize.self) { $0.size } action: { controller.size = $0 }
                .gesture(
                    DragGesture(minimumDistance: LevelGestureController.minimumDistance)
                        .updating($dragging) { _, state, _ in if !state { state = true } }
                        .onChanged { controller.changed($0, canStart: canStart) }
                )
                .onChange(of: dragging) { _, isDragging in
                    if !isDragging { controller.ended() }
                }
        } else {
            content          // setting off: no gesture is attached at all
        }
    }
}

extension View {
    /// Left side: brightness. Right side: volume. `canStart` is asked once at the start of each swipe.
    func levelGestures(enabled: Bool, controller: LevelGestureController,
                       canStart: @escaping () -> Bool) -> some View {
        modifier(LevelGestureModifier(enabled: enabled, controller: controller, canStart: canStart))
    }
}
