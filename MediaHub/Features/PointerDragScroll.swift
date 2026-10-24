import SwiftUI
import UIKit

/// Lets a mouse or trackpad click-drag scroll the scroll view around this content, like a finger. A UIScrollView only
/// pans with direct touches by default, so a pointer drag does nothing until its pan recognizer also takes indirect
/// pointers. Put it on the content stack inside the ScrollView, not on the ScrollView itself.
private struct PointerDragScrollModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            PointerDragScrollProbe()
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Lets a mouse or trackpad click-drag scroll the enclosing scroll view.
    func pointerDragScroll() -> some View { modifier(PointerDragScrollModifier()) }
}

/// A transparent, non-interactive view placed inside the scroll content. It walks up to the UIScrollView it sits in and
/// adds indirect pointers to that scroll view's pan recognizer.
private struct PointerDragScrollProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { enablePointerDrag() }
        }

        /// Keeps the touch types the recognizer already has and adds direct touches and indirect pointers. It stops
        /// once indirect pointers are in, so the recognizer is only written once per scroll view.
        private func enablePointerDrag() {
            var ancestor: UIView? = superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            guard let scroll = ancestor as? UIScrollView else { return }
            let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
            let indirect = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            let pan = scroll.panGestureRecognizer
            let current = pan.allowedTouchTypes
            guard !current.contains(indirect) else { return }
            pan.allowedTouchTypes = current + [direct, indirect].filter { !current.contains($0) }
        }
    }
}
