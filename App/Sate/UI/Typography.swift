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
    /// Point sizes for sans-serif (Atkinson Hyperlegible Next), adhering to standard HIG metrics.
    var sansPointSize: CGFloat {
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

    /// Line spacing in points following accessible typography standards (~1.45–1.50x line-height ratio).
    var accessibleLineSpacing: CGFloat {
        switch self {
        case .largeTitle: 6.0
        case .title: 5.0
        case .title2: 4.5
        case .title3: 4.0
        case .headline: 4.0
        case .body: 5.5
        case .callout: 4.5
        case .subheadline: 4.0
        case .footnote: 3.0
        case .caption: 2.5
        case .caption2: 2.0
        @unknown default: 4.0
        }
    }
}

extension View {
    /// Applies accessible line spacing for the specified text style.
    func appLineSpacing(_ textStyle: Font.TextStyle = .body) -> some View {
        lineSpacing(textStyle.accessibleLineSpacing)
    }

    /// Applies accessible styling for Form section footers.
    func settingsSectionFooter() -> some View {
        font(.appSans(.footnote))
            .appLineSpacing(.footnote)
            .foregroundStyle(.secondary)
    }

    /// Applies accessible styling for Form section headers.
    func settingsSectionHeader() -> some View {
        font(.appSans(.footnote, weight: .semibold))
            .foregroundStyle(.secondary)
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
