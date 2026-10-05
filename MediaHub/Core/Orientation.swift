import SwiftUI
import UIKit

/// App-wide orientation control. The UI is locked to portrait; the video player temporarily unlocks landscape
/// (both orientations) while it is on screen and restores portrait when it goes away.
enum OrientationLock {
    /// True while a player screen is visible. `AppDelegate` hands the window scene exactly this mask.
    @MainActor static var playerActive = false {
        didSet { if oldValue != playerActive { AppDelegate.applyOrientation() } }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.maskNow
    }

    private static var maskNow: UIInterfaceOrientationMask {
        OrientationLock.playerActive ? [.landscapeLeft, .landscapeRight] : .portrait
    }

    /// Pushes the current mask to the foreground window scene. `requestGeometryUpdate` both updates the scene's
    /// effective geometry preferences and asks the system to rotate immediately.
    /// Called on every player appear/disappear, so repeated enter/exit cycles never leave the app stuck in landscape.
    static func applyOrientation() {
        guard let scene = activeScene else { return }
        // iOS 16+ real API: updates the scene's geometry preferences and requests the rotation in one call.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: maskNow)) { _ in }
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

extension View {
    /// Locks the interface to landscape (both directions) while this view is on screen and restores portrait
    /// when it disappears — reliably, even across repeated present/dismiss cycles of a full-screen cover.
    func landscapeWhileVisible() -> some View { modifier(LandscapeWhileVisible()) }
}

private struct LandscapeWhileVisible: ViewModifier {
    /// True while the presented view is laid out wider than tall — i.e. the interface actually rotated into
    /// landscape. Fed by `OrientationProbe` below.
    @State private var isLandscape = false

    func body(content: Content) -> some View {
        content
            .background(OrientationProbe { landscape in isLandscape = landscape })
            // Belt and braces: if the system keeps the cover portrait, rotate the content itself into
            // landscape rather than leaving the viewer with a tiny letterboxed video.
            .rotationEffect(.degrees(isLandscape ? 0 : 90))
            .statusBarHidden(true)
            .onAppear { OrientationLock.playerActive = true }
            .onDisappear { OrientationLock.playerActive = false }
    }
}

/// Geometry reader that reports whether the space it occupies is currently landscape-shaped. When the
/// `requestGeometryUpdate` above succeeds, the full-screen cover grows wider than tall and the report flips
/// to true; if the system refuses to rotate, it stays portrait-shaped and the fallback rotation kicks in.
private struct OrientationProbe: View {
    let onChange: (Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size.width > proxy.size.height) }
                .onChange(of: proxy.size) { _, size in
                    onChange(size.width > size.height)
                }
        }
        .allowsHitTesting(false)
    }
}
