import SwiftUI

/// Sources row rendered under assistant turns with search results (R4.3).
///
/// Collapsed: a compact row of domain/site chips with an expand button.
/// Expanded: detailed cards showing title, snippet, published date, and link.
///
/// Chips and buttons are navigation chrome, so they sit on Liquid Glass;
/// message content itself remains plain.
struct SourcesView: View {
    let sources: [SearchResult]
    @State private var isExpanded = false

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                headerRow

                if isExpanded {
                    expandedCards
                } else {
                    collapsedChips
                }
            }
            .padding(.top, 4)
        }
    }

    private var headerRow: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.appSans(.caption2, weight: .semibold))
                Text("\(sources.count) \(sources.count == 1 ? "source" : "sources")")
                    .font(.appSans(.caption2, weight: .semibold))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.appSans(.caption2))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse \(sources.count) sources" : "Expand \(sources.count) sources")
    }

    private var collapsedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Text("[\(index + 1)]")
                                    .font(.appSans(.caption2, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                                Text(displayName(for: source))
                                    .font(.appSans(.caption2))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glassEffect(.regular, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var expandedCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .center, spacing: 6) {
                                Text("[\(index + 1)]")
                                    .font(.appSans(.caption, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                                Text(displayName(for: source))
                                    .font(.appSans(.caption, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let date = source.publishedAt {
                                    Text(date, format: .dateTime.month().day().year())
                                        .font(.appSans(.caption2))
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "arrow.up.right")
                                    .font(.appSans(.caption2))
                                    .foregroundStyle(.secondary)
                            }

                            Text(source.title)
                                .font(.appSans(.footnote, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if !source.snippet.isEmpty {
                                Text(source.snippet)
                                    .font(.appSans(.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func displayName(for source: SearchResult) -> String {
        if let siteName = source.siteName, !siteName.isEmpty {
            return siteName
        }
        if let url = URL(string: source.url), let host = url.host() {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return "Source"
    }
}
