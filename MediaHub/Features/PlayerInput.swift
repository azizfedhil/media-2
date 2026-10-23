import SwiftUI
import UIKit

struct PlayerKeyActions {
    var togglePlay: () -> Void
    var seek: (Double) -> Void
    var volume: (Double) -> Void
    var mute: () -> Void
    var subtitles: () -> Void
    var nextEpisode: () -> Void
    var escape: () -> Void
    var enabled: () -> Bool
}

/// Transparent full-screen surface under the player controls. Touch taps behave as before (tap the video to toggle the
/// controls); a pointer click plays/pauses, hover brings the controls back, and a trackpad / mouse wheel adjusts the
/// volume (vertical) or seeks (horizontal). The wheel is ignored while a panel is open so its lists scroll normally.
struct PlayerPointerSurface: UIViewRepresentable {
    var onTouchTap: () -> Void
    var onClick: () -> Void
    var onPointerMoved: () -> Void
    var onVolumeStep: (Int) -> Void
    var onSeekStep: (Int) -> Void
    var panelOpen: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        context.coordinator.install(on: view)
        context.coordinator.setPanelOpen(panelOpen)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setPanelOpen(panelOpen)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerPointerSurface

        private let touchTap = UITapGestureRecognizer(target: nil, action: nil)
        private let pointerTap = UITapGestureRecognizer(target: nil, action: nil)
        private let hover = UIHoverGestureRecognizer(target: nil, action: nil)
        private let pan = UIPanGestureRecognizer(target: nil, action: nil)

        private enum Axis: Equatable { case none, horizontal, vertical }
        private var axis: Axis = .none
        private var axisX: CGFloat = 0
        private var axisY: CGFloat = 0
        private var accX: CGFloat = 0
        private var accY: CGFloat = 0

        private static let axisThreshold: CGFloat = 6
        private static let seekStep: CGFloat = 40
        private static let volumeStep: CGFloat = 24

        init(_ parent: PlayerPointerSurface) {
            self.parent = parent
        }

        func install(on view: UIView) {
            touchTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            touchTap.addTarget(self, action: #selector(handleTouchTap))
            touchTap.delegate = self
            view.addGestureRecognizer(touchTap)

            pointerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            pointerTap.addTarget(self, action: #selector(handlePointerTap))
            pointerTap.delegate = self
            view.addGestureRecognizer(pointerTap)

            hover.addTarget(self, action: #selector(handleHover(_:)))
            hover.delegate = self
            view.addGestureRecognizer(hover)

            pan.allowedScrollTypesMask = [.continuous, .discrete]
            pan.allowedTouchTypes = []
            pan.addTarget(self, action: #selector(handlePan(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
        }

        func setPanelOpen(_ open: Bool) {
            pan.isEnabled = !open
        }

        @objc private func handleTouchTap() {
            parent.onTouchTap()
        }

        @objc private func handlePointerTap() {
            parent.onClick()
        }

        @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
            switch gesture.state {
            case .began, .changed: parent.onPointerMoved()
            default: break
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                reset()
            case .changed:
                let t = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                if axis == .none {
                    axisX += t.x
                    axisY += t.y
                    guard max(abs(axisX), abs(axisY)) >= Self.axisThreshold else { return }
                    axis = abs(axisX) >= abs(axisY) ? .horizontal : .vertical
                }
                switch axis {
                case .horizontal:
                    accX += t.x
                    while abs(accX) >= Self.seekStep {
                        let step = accX > 0 ? 1 : -1
                        parent.onSeekStep(step)
                        accX -= CGFloat(step) * Self.seekStep
                    }
                case .vertical:
                    accY += t.y
                    while abs(accY) >= Self.volumeStep {
                        let step = accY < 0 ? 1 : -1
                        parent.onVolumeStep(step)
                        accY += CGFloat(step) * Self.volumeStep
                    }
                case .none:
                    break
                }
            case .ended, .cancelled, .failed:
                reset()
            default:
                break
            }
        }

        private func reset() {
            axis = .none
            axisX = 0
            axisY = 0
            accX = 0
            accY = 0
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gestureRecognizer === hover && other === pan) || (gestureRecognizer === pan && other === hover)
        }
    }
}

struct PlayerKeyInput: UIViewControllerRepresentable {
    let actions: PlayerKeyActions
    let focusTick: Int

    func makeUIViewController(context: Context) -> PlayerKeyController {
        PlayerKeyController(actions: actions, focusTick: focusTick)
    }

    func updateUIViewController(_ uiViewController: PlayerKeyController, context: Context) {
        uiViewController.update(actions: actions, focusTick: focusTick)
    }

    static func dismantleUIViewController(_ uiViewController: PlayerKeyController, coordinator: ()) {
        uiViewController.resignFirstResponder()
    }
}

private struct PlayerKeyStroke: Hashable {
    let input: String
    let shift: Bool

    init(_ input: String, shift: Bool = false) {
        self.input = input
        self.shift = shift
    }
}

private enum PlayerKeyAction {
    case togglePlay
    case seek(Double)
    case volume(Double)
    case mute
    case subtitles
    case nextEpisode
    case escape
}

final class PlayerKeyController: UIViewController {
    private var actions: PlayerKeyActions
    private var lastFocusTick: Int

    init(actions: PlayerKeyActions, focusTick: Int) {
        self.actions = actions
        self.lastFocusTick = focusTick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? { Self.commands }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resignFirstResponder()
    }

    func update(actions: PlayerKeyActions, focusTick: Int) {
        self.actions = actions
        guard focusTick != lastFocusTick else { return }
        lastFocusTick = focusTick
        becomeFirstResponder()
    }

    private static var commands: [UIKeyCommand] {
        bindings.map { (stroke, _) in
            let command = UIKeyCommand(input: stroke.input,
                                       modifierFlags: stroke.shift ? .shift : [],
                                       action: #selector(PlayerKeyController.handle(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    private static let bindings: [PlayerKeyStroke: PlayerKeyAction] = [
        PlayerKeyStroke(" "): .togglePlay,
        PlayerKeyStroke(UIKeyCommand.inputLeftArrow): .seek(-10),
        PlayerKeyStroke(UIKeyCommand.inputRightArrow): .seek(10),
        PlayerKeyStroke(UIKeyCommand.inputLeftArrow, shift: true): .seek(-30),
        PlayerKeyStroke(UIKeyCommand.inputRightArrow, shift: true): .seek(30),
        PlayerKeyStroke("j"): .seek(-10),
        PlayerKeyStroke("l"): .seek(10),
        PlayerKeyStroke("k"): .togglePlay,
        PlayerKeyStroke(UIKeyCommand.inputUpArrow): .volume(0.05),
        PlayerKeyStroke(UIKeyCommand.inputDownArrow): .volume(-0.05),
        PlayerKeyStroke("m"): .mute,
        PlayerKeyStroke("c"): .subtitles,
        PlayerKeyStroke("n", shift: true): .nextEpisode,
        PlayerKeyStroke(UIKeyCommand.inputEscape): .escape
    ]

    @objc private func handle(_ command: UIKeyCommand) {
        let flags = command.modifierFlags
        guard !flags.contains(.control), !flags.contains(.alternate), !flags.contains(.command) else { return }
        let input = (command.input ?? "").lowercased()
        let stroke = PlayerKeyStroke(input, shift: flags.contains(.shift))
        guard let action = Self.bindings[stroke] else { return }
        if case .escape = action {
            actions.escape()
            return
        }
        guard actions.enabled() else { return }
        switch action {
        case .togglePlay:
            actions.togglePlay()
        case .seek(let seconds):
            actions.seek(seconds)
        case .volume(let delta):
            actions.volume(delta)
        case .mute:
            actions.mute()
        case .subtitles:
            actions.subtitles()
        case .nextEpisode:
            actions.nextEpisode()
        case .escape:
            break
        }
    }
}
