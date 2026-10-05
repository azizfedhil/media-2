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
        maskNow
    }

    private var supportedInterfaceOrientationsFor: UIInterfaceOrientationMask { maskNow }

    private static var maskNow: UIInterfaceOrientationMask {
        OrientationLock.playerActive ? [.landscapeLeft, .landscapeRight] : .portrait
    }

    /// Re-asks the system for the current mask and snaps back to portrait as soon as the player closes.
    /// Called on every player appear/disappear, so repeated enter/exit cycles never leave the app stuck in landscape.
    static func applyOrientation() {
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: maskNow)) { _ in }
        scene.coordinator.updateGeometryPreferences()
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
    @Environment(\.displayRotationAngle) private var rotation

    func body(content: Content) -> some View {
        content
            // Belt and braces: if the system keeps the cover portrait, rotate the content itself into
            // landscape rather than leaving the viewer with a tiny letterboxed video.
            .rotationEffect(.degrees(rotation.angle == 0 ? 90 : 0))
            .statusBarHidden(true)
            .onAppear { OrientationLock.playerActive = true }
            .onDisappear { OrientationLock.playerActive = false }
    }
}

private extension UIInterfaceOrientation.Angle {
    /// Non-zero only while the interface is actually rotated, so the fallback kick-in above stays invisible
    /// whenever the geometry update succeeded.
    var angle: Double {
        switch self {
        case .up: return 0
        case .down: return 180
        case .right: return 90
        case .left: return -90
        @unknown default: return 0
        }
    }
}
