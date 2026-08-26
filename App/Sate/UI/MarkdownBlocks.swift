import SwiftUI

// MARK: - Block model

/// One rendered block of markdown.
///
/// `AttributedString(markdown:)` only produces *inline* intents that `Text` can
/// draw (bold, italic, code, link, strikethrough). Block structure — headings,
/// fenced code, quotes, lists — arrives as `presentationIntent` runs that `Text`
/// silently ignores, so the block layer is parsed here and mapped onto real
/// SwiftUI views. No third-party markdown library is used or allowed.
struct MarkdownBlock: Identifiable, Hashable {
    enum Kind: Hashable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `isClosed == false` means the source ended inside the fence: a fence
        /// still being streamed. It renders as code-in-progress, never as an error.
        case code(language: String?, code: String, isClosed: Bool)
        case quote(String)
        case list(ordered: Bool, start: Int, items: [String])
        case rule
    }

    /// Positional. Stable for a given source string, which is all `ForEach` needs
    /// — committed messages never mutate, and the streaming view re-renders only
    /// its trailing paragraph.
    let id: Int
    let kind: Kind
}

// MARK: - Fence detection

/// An opened code fence: which marker, how long, and its info string.
/// Shared by the block parser and the streaming paragraph splitter so both agree
/// on exactly what a fence is.
struct MarkdownFence: Hashable {
    let marker: Character
    let length: Int
    let info: String

    /// A fence opener is 3+ backticks or tildes. A backtick fence whose info
    /// string contains a backtick is not a fence (CommonMark), which keeps
    /// inline spans like `` `a` `` from being mistaken for one.
    static func opener(_ line: Substring) -> MarkdownFence? {
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let run = body.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") {
            return nil
        }
        return MarkdownFence(marker: first, length: run.count, info: info)
    }

    func closes(_ line: Substring) -> Bool {
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard body.first == marker else { return false }
        let run = body.prefix { $0 == marker }
        guard run.count >= length else { return false }
        return body.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

// MARK: - Paragraph splitting (streaming)

enum MarkdownParagraphs {
    /// Splits text into paragraphs on blank lines, **skipping blank lines inside
    /// a code fence**. `StreamingMessageView` freezes every paragraph but the
    /// last, so a naive split would tear a code block apart the moment it
    /// contained an empty line.
    ///
    /// Deliberately allocation-light: it only materializes a `String` for lines
    /// that could plausibly be a fence, because this runs on every token flush.
    static func split(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current: [Substring] = []
        var openFence: MarkdownFence?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let fence = openFence {
                current.append(line)
                if fence.closes(line) {
                    openFence = nil
                }
                continue
            }
            let leading = line.first
            if leading == "`" || leading == "~" || leading == " " || leading == "\t" {
                if let fence = MarkdownFence.opener(line) {
                    openFence = fence
                    current.append(line)
                    continue
                }
            }
            if line.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }
            current.append(line)
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: "\n"))
        }
        return paragraphs
    }
}

// MARK: - Block parsing

enum MarkdownBlockParser {
    private struct ListItem {
        let ordered: Bool
        let number: Int?
        let text: String
    }

    /// Never throws and never returns an empty result for non-empty input:
    /// anything it does not recognise degrades to a paragraph.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var nextID = 0
        var paragraph: [String] = []

        func emit(_ kind: MarkdownBlock.Kind) {
            blocks.append(MarkdownBlock(id: nextID, kind: kind))
            nextID += 1
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            emit(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = MarkdownFence.opener(line) {
                flushParagraph()
                index += 1
                var body: [Substring] = []
                var closed = false
                while index < lines.count {
                    if fence.closes(lines[index]) {
                        closed = true
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                emit(.code(
                    language: fence.info.isEmpty ? nil : fence.info,
                    code: body.joined(separator: "\n"),
                    isClosed: closed
                ))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                emit(.rule)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                emit(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var rest = candidate.dropFirst()
                    if rest.first == " " {
                        rest = rest.dropFirst()
                    }
                    quoted.append(String(rest))
                    index += 1
                }
                emit(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if let first = listItem(trimmed) {
                flushParagraph()
                var items: [String] = []
                let ordered = first.ordered
                let start = first.number ?? 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = listItem(candidate), item.ordered == ordered else { break }
                    items.append(item.text)
                    index += 1
                    // Indented follow-on lines belong to the item just emitted.
                    while index < lines.count {
                        let raw = lines[index]
                        guard raw.first == " " || raw.first == "\t" else { break }
                        let continuation = raw.trimmingCharacters(in: .whitespaces)
                        guard !continuation.isEmpty, listItem(continuation) == nil else { break }
                        items[items.count - 1] += "\n" + continuation
                        index += 1
                    }
                }
                emit(.list(ordered: ordered, start: start, items: items))
                continue
            }

            paragraph.append(String(line))
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let squished = trimmed.filter { !$0.isWhitespace }
        guard squished.count >= 3, let first = squished.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return squished.allSatisfy { $0 == first }
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.first == "#" else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1 ... 6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ trimmed: String) -> ListItem? {
        if let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+" {
            let rest = trimmed.dropFirst()
            guard rest.first == " " else { return nil }
            return ListItem(ordered: false, number: nil, text: rest.trimmingCharacters(in: .whitespaces))
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        var rest = trimmed.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return ListItem(
            ordered: true,
            number: Int(digits),
            text: rest.trimmingCharacters(in: .whitespaces)
        )
    }
}

// MARK: - Inline rendering

enum MarkdownInline {
    /// `.inlineOnlyPreservingWhitespace` is required: the default `.full` syntax
    /// collapses newlines and hard-wraps, which destroys the line structure of a
    /// paragraph that the block parser already decided to keep together.
    ///
    /// `returnPartiallyParsedIfPossible` plus the `??` fallback guarantee that a
    /// half-written emphasis run or a stray bracket from a partial stream renders
    /// as literal text rather than blanking the message.
    static func attributed(_ source: String, sources: [SearchResult]? = nil) -> AttributedString {
        let prepared = prepareCitations(source, sources: sources)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.allowsExtendedAttributes = true
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: prepared, options: options)) ?? AttributedString(source)
    }

    /// Links `[n]` citation markers to their corresponding source URLs (R4.4).
    private static func prepareCitations(_ text: String, sources: [SearchResult]?) -> String {
        guard let sources, !sources.isEmpty else { return text }
        // Match [1], [2], etc. that are not already markdown links or code spans
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\[|\`|\\)\[([1-9][0-9]?)\](?!\(|\`|\])"#) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastIndex = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let numRange = Range(match.range(at: 1), in: text),
                  let num = Int(text[numRange]),
                  sources.indices.contains(num - 1)
            else { continue }

            let url = sources[num - 1].url
            result += text[lastIndex ..< matchRange.lowerBound]
            result += "[\(num)](\(url))"
            lastIndex = matchRange.upperBound
        }

        result += text[lastIndex...]
        return result
    }
}

// MARK: - Block cache

/// Parsed blocks are cached per source string: committed transcripts are
/// re-rendered on every scroll pass through the `LazyVStack`, and re-parsing a
/// long answer each time would show up as scroll jank.
@MainActor
enum MarkdownCache {
    private static let limit = 240
    private static var storage: [String: [MarkdownBlock]] = [:]
    private static var order: [String] = []

    static func blocks(for source: String) -> [MarkdownBlock] {
        if let cached = storage[source] {
            return cached
        }
        let parsed = MarkdownBlockParser.parse(source)
        storage[source] = parsed
        order.append(source)
        if order.count > limit {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
        return parsed
    }

    /// Called when a conversation is closed (R2.6): the cache is per-message and
    /// there is no reason to hold another conversation's transcript in memory.
    static func clear() {
        storage.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }
}

// MARK: - Views

/// Renders committed markdown. The in-flight message deliberately does *not* use
/// this — see `StreamingMessageView`.
struct MarkdownBlocksView: View, Equatable {
    let source: String
    var sources: [SearchResult]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownCache.blocks(for: source)) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case let .paragraph(text):
            Text(MarkdownInline.attributed(text, sources: sources))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .heading(level, text):
            Text(MarkdownInline.attributed(text, sources: sources))
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)

        case let .code(language, code, isClosed):
            CodeBlockView(language: language, code: code, isClosed: isClosed)

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                Text(MarkdownInline.attributed(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(start + offset)." : "•")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(MarkdownInline.attributed(item))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}

/// Fenced code lives in its own horizontal `ScrollView` so a single long line
/// never widens the transcript and makes the whole page scroll sideways.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    let isClosed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        // An unclosed fence is normal mid-stream; the hairline says "still coming"
        // without implying the markdown is broken.
        .overlay(alignment: .bottom) {
            if !isClosed {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(height: 2)
            }
        }
        .accessibilityLabel(language.map { "Code block, \($0)" } ?? "Code block")
    }
}
