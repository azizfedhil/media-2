import SwiftUI
import UIKit

/// App-wide orientation policy.
///
/// The whole app is portrait-only (see `UIAppSupportedInterfaceOrientations` in project.yml, which lands in the
/// generated Info.plist). A player presented over it asks UIKit for a landscape mask containing both landscape
/// directions; when the player goes away the mask is restored to portrait. Repeated entry/exit just re-runs the
/// same two requests, so the app can never be left stuck in landscape by an unbalanced call.
///
/// This uses the real iOS 16+ window-geometry API (`UIWindowScene.requestGeometryUpdate(_:)`) — a genuine
/// interface-orientation change, not a `.rotationEffect` trick — and touches nothing inside AetherEngine.
enum OrientationCoordinator {
    /// Landscape-left + landscape-right: the device may be rotated 180° while the player is up.
    static let playerMask: UIInterfaceOrientationMask = [.landscapeLeft, .landscapeRight]
    static let portraitMask: UIInterfaceOrientationMask = .portrait

    /// Requests the given orientation mask on every connected foreground scene.
    @MainActor
    static func request(_ mask: UIInterfaceOrientationMask) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            switch scene.activationState {
            case .foregroundActive, .foregroundInactive:
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            default:
                break
            }
        }
    }
}

private struct PlayerLandscapeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Ask for landscape as soon as the player starts appearing, before its own task runs.
            .onAppear { OrientationCoordinator.request(OrientationCoordinator.playerMask) }
            .onDisappear { OrientationCoordinator.request(OrientationCoordinator.portraitMask) }
    }
}

extension View {
    /// Locks the presented player to landscape (both directions) while it is on screen; restoring portrait on exit.
    func playerLandscape() -> some View { modifier(PlayerLandscapeModifier()) }
}
