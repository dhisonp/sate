import CoreText
import Foundation
import SwiftUI

enum AppFont {
    static let sansFamily = "Atkinson Hyperlegible Next"
    static let monoFamily = "Atkinson Hyperlegible Mono"

    static func registerFonts() {
        var urls: [URL] = []
        if let bundleURLs = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) {
            urls.append(contentsOf: bundleURLs)
        }
        if urls.isEmpty {
            for bundle in Bundle.allBundles {
                if let bundleURLs = bundle.urls(forResourcesWithExtension: "otf", subdirectory: nil) {
                    urls.append(contentsOf: bundleURLs)
                }
            }
        }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { _, _ in
            true
        }
    }
}

extension Font.TextStyle {
    /// Point sizes for sans-serif (Atkinson Hyperlegible Next), slightly bumped
    /// for enhanced legibility and generous character distinction.
    var sansPointSize: CGFloat {
        switch self {
        case .largeTitle: 36
        case .title: 30
        case .title2: 24
        case .title3: 21
        case .headline: 18
        case .body: 18
        case .callout: 17
        case .subheadline: 16
        case .footnote: 14
        case .caption: 13
        case .caption2: 12
        @unknown default: 18
        }
    }

    /// Point sizes for monospaced (Atkinson Hyperlegible Mono), adhering to standard HIG metrics.
    var monoPointSize: CGFloat {
        switch self {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }

    var defaultPointSize: CGFloat {
        sansPointSize
    }

    /// Line spacing in points following accessible typography standards tuned
    /// for Atkinson Hyperlegible's metrics on the tighter side (~1.30–1.36x ratio).
    var accessibleLineSpacing: CGFloat {
        switch self {
        case .largeTitle, .title: 3.0
        case .title2, .title3, .headline: 2.5
        case .body: 3.5
        case .callout: 3.0
        case .subheadline: 2.5
        case .footnote: 2.0
        case .caption, .caption2: 1.5
        @unknown default: 3.0
        }
    }
}

extension View {
    /// Applies accessible line spacing for the specified text style.
    func appLineSpacing(_ textStyle: Font.TextStyle = .body) -> some View {
        lineSpacing(textStyle.accessibleLineSpacing)
    }
}

extension Font {
    static func appSans(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        appSans(size: textStyle.sansPointSize, weight: weight, relativeTo: textStyle)
    }

    static func appMono(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        appMono(size: textStyle.monoPointSize, weight: weight, relativeTo: textStyle)
    }

    static func appSans(size: CGFloat, weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body) -> Font {
        .custom(AppFont.sansFamily, size: size, relativeTo: relativeTo).weight(weight)
    }

    static func appMono(size: CGFloat, weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body) -> Font {
        .custom(AppFont.monoFamily, size: size, relativeTo: relativeTo).weight(weight)
    }
}
