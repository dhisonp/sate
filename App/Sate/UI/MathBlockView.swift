import SwiftUI
import UIKit

/// Equations render in an isolated horizontal ScrollView to prevent wide
/// formulas from expanding the transcript container or causing horizontal jank.
struct MathBlockView: View {
    let equation: String
    let raw: String
    let isClosed: Bool
    var cachedAttributed: AttributedString?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Equation", systemImage: "function")
                    .font(.appSans(.caption2, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = raw
                    withAnimation(.snappy(duration: 0.2)) {
                        copied = true
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.snappy(duration: 0.2)) {
                            copied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy LaTeX")
                    }
                    .font(.appSans(.caption2))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy equation LaTeX")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.horizontal) {
                Text(cachedAttributed ?? MarkdownInline.attributedMath(equation))
                    .font(.appSans(.body))
                    .appLineSpacing(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            if !isClosed {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(height: 2)
            }
        }
        .accessibilityLabel("Equation: \(equation)")
    }
}
