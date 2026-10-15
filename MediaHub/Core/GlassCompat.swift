import SwiftUI

// Pear. is built with the iOS 26 SDK and deploys to iOS 18.
// The helpers below draw Liquid Glass on iOS 26 and later, and the closest system material on
// iOS 18 and 25, so each screen keeps one call site and adapts to the system it runs on.

// MARK: - Glass surfaces

@available(iOS 26.0, *)
private func pearGlassStyle(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// A glass surface in `shape`. `tint` colours it and `interactive` makes it respond to touch (iOS 26).
    /// Before iOS 26 it is a material fill, or a flat fill in `tint` when one is given.
    @ViewBuilder
    func pearGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(pearGlassStyle(tint: tint, interactive: interactive), in: shape)
        } else {
            if let tint {
                self.background(tint, in: shape)
            } else {
                self.background(.ultraThinMaterial, in: shape)
            }
        }
    }

    /// Glass button style on iOS 26. Bordered button styles on iOS 18 and 25.
    @ViewBuilder
    func pearGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    /// The tab bar shrinks while scrolling down (iOS 26). It stays put before that.
    @ViewBuilder
    func pearMinimizeTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// Hides the soft fade at the top of a scroll view (iOS 26). There is no such fade before that.
    @ViewBuilder
    func pearHideTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }

    /// Subtitle under the large navigation title (iOS 26). Left out before that.
    @ViewBuilder
    func pearNavigationSubtitle(_ subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}

/// Groups glass surfaces so they blend and share one sampling pass (iOS 26). A plain stack before that.
struct PearGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
