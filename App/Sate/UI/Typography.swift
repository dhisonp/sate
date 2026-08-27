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
    var defaultPointSize: CGFloat {
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
}

extension Font {
    static func appSans(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        appSans(size: textStyle.defaultPointSize, weight: weight, relativeTo: textStyle)
    }

    static func appMono(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        appMono(size: textStyle.defaultPointSize, weight: weight, relativeTo: textStyle)
    }

    static func appSans(size: CGFloat, weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body) -> Font {
        .custom(AppFont.sansFamily, size: size, relativeTo: relativeTo).weight(weight)
    }

    static func appMono(size: CGFloat, weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body) -> Font {
        .custom(AppFont.monoFamily, size: size, relativeTo: relativeTo).weight(weight)
    }
}
