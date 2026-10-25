import SwiftUI
import UIKit

// MARK: - Mouse / trackpad click-drag scrolling

/// Kept so existing call sites compile. Pointer drag scrolling is handled once for the whole window by
/// `PointerInputHost` below, so rows and lists no longer need to opt in one by one.
extension View {
    func pointerDragScroll() -> some View { self }
}

/// Put once on the app's root view. It installs one recognizer on the window that lets a mouse or trackpad
/// click-drag scroll whatever scroll view is under the pointer, like a finger does.
///
/// Why one recognizer on the window and not a tweak to each UIScrollView's own pan: widening a scroll view's
/// pan to indirect pointers only reached the scroll views that opted in (so some rows dragged and others did not),
/// and it made the scroll view hold or swallow plain clicks. This recognizer only begins once the pointer has
/// actually moved, so a click without movement is never touched, and it hands the touch back to nothing: once it
/// begins, the click is cancelled for the control under it, which is what a drag should do.
struct PointerInputHost: UIViewRepresentable {
    func makeUIView(context: Context) -> HostView { HostView() }
    func updateUIView(_ uiView: HostView, context: Context) {}

    final class HostView: UIView {
        private var driver: PointerScrollDriver?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            if driver?.window !== window {
                driver?.uninstall()
                driver = PointerScrollDriver(window: window)
            }
        }
    }
}

@MainActor
final class PointerScrollDriver: NSObject, UIGestureRecognizerDelegate {
    private(set) weak var window: UIWindow?

    private let pan = UIPanGestureRecognizer()
    /// Reports a finger touching down, without ever taking the touch, so the app knows the last input was touch.
    private let touchProbe = UILongPressGestureRecognizer()

    private enum Axis { case horizontal, vertical }
    private weak var pending: UIScrollView?
    private var pendingAxis: Axis = .vertical
    private weak var target: UIScrollView?
    private var axis: Axis = .vertical
    private var startOffset: CGPoint = .zero

    private var link: CADisplayLink?
    private var momentumVelocity: CGFloat = 0
    private var lastTick: CFTimeInterval = 0

    init(window: UIWindow) {
        self.window = window
        super.init()

        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.delegate = self
        window.addGestureRecognizer(pan)

        touchProbe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        touchProbe.minimumPressDuration = 0
        touchProbe.cancelsTouchesInView = false
        touchProbe.delaysTouchesBegan = false
        touchProbe.delaysTouchesEnded = false
        touchProbe.addTarget(self, action: #selector(handleTouch(_:)))
        touchProbe.delegate = self
        window.addGestureRecognizer(touchProbe)
    }

    func uninstall() {
        stopMomentum()
        window?.removeGestureRecognizer(pan)
        window?.removeGestureRecognizer(touchProbe)
    }

    // MARK: Delegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let window else { return true }
        let t = pan.translation(in: window)
        let dir: Axis = abs(t.x) > abs(t.y) ? .horizontal : .vertical
        var view: UIView? = window.hitTest(pan.location(in: window), with: nil)
        while let v = view {
            if let scroll = v as? UIScrollView, canScroll(scroll, dir) {
                pending = scroll
                pendingAxis = dir
                return true
            }
            view = v.superview
        }
        // Nothing under the pointer scrolls that way (a slider, a button, empty space): leave the drag alone.
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === touchProbe || other === touchProbe
    }

    // MARK: Scrolling

    @objc private func handleTouch(_ g: UILongPressGestureRecognizer) {
        if g.state == .began, InputState.shared.pointerActive { InputState.shared.pointerActive = false }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            stopMomentum()
            target = pending
            axis = pendingAxis
            startOffset = target?.contentOffset ?? .zero
        case .changed:
            guard let scroll = target else { return }
            let t = g.translation(in: scroll.superview ?? window)
            var o = startOffset
            switch axis {
            case .horizontal: o.x = clamp(startOffset.x - t.x, scroll, .horizontal)
            case .vertical: o.y = clamp(startOffset.y - t.y, scroll, .vertical)
            }
            scroll.setContentOffset(o, animated: false)
        case .ended:
            guard let scroll = target else { return }
            let v = g.velocity(in: scroll.superview ?? window)
            finish(scroll, velocity: -(axis == .horizontal ? v.x : v.y))
        default:
            target = nil
        }
    }

    private func canScroll(_ s: UIScrollView, _ a: Axis) -> Bool {
        guard s.isScrollEnabled, !(s is UITextView) else { return false }
        return range(s, a).upperBound - range(s, a).lowerBound > 1
    }

    private func range(_ s: UIScrollView, _ a: Axis) -> ClosedRange<CGFloat> {
        let i = s.adjustedContentInset
        switch a {
        case .horizontal:
            let lo = -i.left
            return lo...max(s.contentSize.width + i.right - s.bounds.width, lo)
        case .vertical:
            let lo = -i.top
            return lo...max(s.contentSize.height + i.bottom - s.bounds.height, lo)
        }
    }

    private func clamp(_ v: CGFloat, _ s: UIScrollView, _ a: Axis) -> CGFloat {
        let r = range(s, a)
        return min(max(v, r.lowerBound), r.upperBound)
    }

    // MARK: Release

    private func finish(_ scroll: UIScrollView, velocity: CGFloat) {
        if scroll.isPagingEnabled {
            let size = axis == .horizontal ? scroll.bounds.width : scroll.bounds.height
            guard size > 0 else { return }
            let current = axis == .horizontal ? scroll.contentOffset.x : scroll.contentOffset.y
            let page = ((current + velocity * 0.12) / size).rounded()
            var o = scroll.contentOffset
            if axis == .horizontal { o.x = clamp(page * size, scroll, .horizontal) } else { o.y = clamp(page * size, scroll, .vertical) }
            scroll.setContentOffset(o, animated: true)
            return
        }
        guard abs(velocity) > 80 else { return }
        momentumVelocity = velocity
        lastTick = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        guard let scroll = target else { stopMomentum(); return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 30.0)
        lastTick = now
        var o = scroll.contentOffset
        let current = axis == .horizontal ? o.x : o.y
        let next = clamp(current + momentumVelocity * dt, scroll, axis == .horizontal ? .horizontal : .vertical)
        if axis == .horizontal { o.x = next } else { o.y = next }
        scroll.setContentOffset(o, animated: false)
        // UIScrollView's normal deceleration: 0.998 per millisecond.
        momentumVelocity *= CGFloat(pow(0.998, dt * 1000))
        if abs(momentumVelocity) < 20 || next == current { stopMomentum() }
    }

    private func stopMomentum() {
        link?.invalidate()
        link = nil
        momentumVelocity = 0
    }
}
