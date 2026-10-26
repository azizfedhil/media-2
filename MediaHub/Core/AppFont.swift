import SwiftUI
import UIKit
import CoreText

/// Archivo, the app-wide typeface. The static TTFs live in Resources/Fonts and are registered at launch
/// (`Archivo.register()`), so no Info.plist entry is needed. If a file is ever missing, SwiftUI falls back to the system font.
enum Archivo {
    /// PostScript names of the bundled faces (not the family names: the files are separate static faces).
    static func postScriptName(_ weight: Font.Weight, italic: Bool = false) -> String {
        if italic { return "ArchivoItalic-Italic" }
        switch weight {
        case .black: return "ArchivoRoman-Black"
        case .heavy: return "ArchivoRoman-ExtraBold"
        case .bold: return "ArchivoRoman-Bold"
        case .semibold: return "ArchivoRoman-SemiBold"
        case .medium: return "ArchivoRoman-Medium"
        default: return "ArchivoRoman-Regular"
        }
    }

    /// Point sizes of the iOS text styles at the default Dynamic Type setting.
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
    }

    /// Registers every bundled Archivo file for this process. Safe to call more than once.
    static func register() {
        let all = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        let urls = all.filter { $0.lastPathComponent.hasPrefix("Archivo") }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// UIKit-drawn text (navigation bar titles, bar buttons). SwiftUI text is covered by `Font.archivo`.
    static func installAppearance() {
        func ui(_ weight: Font.Weight, _ size: CGFloat) -> UIFont? { UIFont(name: postScriptName(weight), size: size) }
        let nav = UINavigationBar.appearance()
        if let f = ui(.semibold, 17) { nav.titleTextAttributes = [.font: f] }
        if let f = ui(.bold, 34) { nav.largeTitleTextAttributes = [.font: f] }
        if let f = ui(.medium, 17) {
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: f], for: .normal)
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: f], for: .highlighted)
        }
    }
}

extension Font {
    /// Archivo at a text style's size, scaling with Dynamic Type like the system styles do. `.headline` is semibold by default.
    static func archivo(_ style: Font.TextStyle, weight: Font.Weight? = nil, italic: Bool = false) -> Font {
        let w = weight ?? (style == .headline ? .semibold : .regular)
        return .custom(Archivo.postScriptName(w, italic: italic), size: Archivo.baseSize(style), relativeTo: style)
    }

    /// Archivo at a fixed point size (the replacement for `.system(size:weight:)`).
    static func archivo(size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        .custom(Archivo.postScriptName(weight, italic: italic), fixedSize: size)
    }
}
