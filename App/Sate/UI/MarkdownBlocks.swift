import SwiftUI
import UIKit

// MARK: - Block model

/// One rendered block of markdown.
///
/// `AttributedString(markdown:)` only produces *inline* intents that `Text` can
/// draw (bold, italic, code, link, strikethrough). Block structure — headings,
/// fenced code, quotes, lists, tables — arrives as `presentationIntent` runs that
/// `Text` silently ignores, so the block layer is parsed here and mapped onto real
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
        /// `isClosed == false` means streaming ended before a closing blank line
        /// or next block, so the table renders as in-progress rather than failing.
        case table(header: [String], rows: [[String]], isClosed: Bool)
        case rule
        case math(equation: String, raw: String, isClosed: Bool)
    }

    /// Positional. Stable for a given source string, which is all `ForEach` needs
    /// — committed messages never mutate, and the streaming view re-renders only
    /// its trailing paragraph.
    let id: Int
    let kind: Kind
    var cachedAttributed: AttributedString?
    var cachedListAttributed: [AttributedString]?
    var cachedTableHeaderAttributed: [AttributedString]?
    var cachedTableRowsAttributed: [[AttributedString]]?

    init(
        id: Int,
        kind: Kind,
        cachedAttributed: AttributedString? = nil,
        cachedListAttributed: [AttributedString]? = nil,
        cachedTableHeaderAttributed: [AttributedString]? = nil,
        cachedTableRowsAttributed: [[AttributedString]]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.cachedAttributed = cachedAttributed
        self.cachedListAttributed = cachedListAttributed
        self.cachedTableHeaderAttributed = cachedTableHeaderAttributed
        self.cachedTableRowsAttributed = cachedTableRowsAttributed
    }

    mutating func precomputeAttributed(sources: [SearchResult]? = nil) {
        switch kind {
        case let .paragraph(text), let .heading(_, text):
            cachedAttributed = MarkdownInline.attributed(text, sources: sources)
        case let .quote(text):
            cachedAttributed = MarkdownInline.attributed(text)
        case let .list(_, _, items):
            cachedListAttributed = items.map { MarkdownInline.attributed($0) }
        case let .table(header, rows, _):
            cachedTableHeaderAttributed = header.map { MarkdownInline.attributed($0, sources: sources) }
            cachedTableRowsAttributed = rows.map { row in
                row.map { MarkdownInline.attributed($0, sources: sources) }
            }
        case let .math(equation, _, _):
            cachedAttributed = MarkdownInline.attributedMath(equation)
        case .code, .rule:
            break
        }
    }
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
                let rawCode = body.joined(separator: "\n")
                if fence.info == "math" || fence.info == "latex" || fence.info == "tex" {
                    emit(.math(
                        equation: MathFormatter.formatEquation(rawCode),
                        raw: rawCode,
                        isClosed: closed
                    ))
                } else {
                    emit(.code(
                        language: fence.info.isEmpty ? nil : fence.info,
                        code: rawCode,
                        isClosed: closed
                    ))
                }
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed.hasPrefix("$$") {
                flushParagraph()
                if trimmed.count > 2, trimmed.dropFirst(2).hasSuffix("$$") {
                    let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                    emit(.math(equation: MathFormatter.formatEquation(inner), raw: inner, isClosed: true))
                    index += 1
                    continue
                } else {
                    var body: [Substring] = []
                    var closed = false
                    let firstLineBody = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if !firstLineBody.isEmpty {
                        body.append(Substring(firstLineBody))
                    }
                    index += 1
                    while index < lines.count {
                        let nextTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                        if nextTrimmed.hasSuffix("$$") {
                            let lastBody = nextTrimmed.dropLast(2).trimmingCharacters(in: .whitespaces)
                            if !lastBody.isEmpty {
                                body.append(Substring(lastBody))
                            }
                            closed = true
                            index += 1
                            break
                        }
                        body.append(lines[index])
                        index += 1
                    }
                    let rawCode = body.joined(separator: "\n")
                    emit(.math(equation: MathFormatter.formatEquation(rawCode), raw: rawCode, isClosed: closed))
                    continue
                }
            }

            if trimmed.hasPrefix("\\[") {
                flushParagraph()
                if trimmed.hasSuffix("\\]"), trimmed.count > 4 {
                    let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                    emit(.math(equation: MathFormatter.formatEquation(inner), raw: inner, isClosed: true))
                    index += 1
                    continue
                } else {
                    var body: [Substring] = []
                    var closed = false
                    let firstLineBody = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if !firstLineBody.isEmpty {
                        body.append(Substring(firstLineBody))
                    }
                    index += 1
                    while index < lines.count {
                        let nextTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                        if nextTrimmed.hasSuffix("\\]") {
                            let lastBody = nextTrimmed.dropLast(2).trimmingCharacters(in: .whitespaces)
                            if !lastBody.isEmpty {
                                body.append(Substring(lastBody))
                            }
                            closed = true
                            index += 1
                            break
                        }
                        body.append(lines[index])
                        index += 1
                    }
                    let rawCode = body.joined(separator: "\n")
                    emit(.math(equation: MathFormatter.formatEquation(rawCode), raw: rawCode, isClosed: closed))
                    continue
                }
            }

            if trimmed.hasPrefix("\\begin{"), let envName = extractEnvironmentName(trimmed), isMathEnvironment(envName) {
                flushParagraph()
                var body: [Substring] = [line]
                var closed = false
                let endMarker = "\\end{\(envName)}"
                if trimmed.contains(endMarker) {
                    closed = true
                    index += 1
                } else {
                    index += 1
                    while index < lines.count {
                        let currentLine = lines[index]
                        body.append(currentLine)
                        if currentLine.contains(endMarker) {
                            closed = true
                            index += 1
                            break
                        }
                        index += 1
                    }
                }
                let rawCode = body.joined(separator: "\n")
                emit(.math(equation: MathFormatter.formatEquation(rawCode), raw: rawCode, isClosed: closed))
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

            if trimmed.contains("|"), index + 1 < lines.count, isTableDelimiterRow(lines[index + 1]) {
                flushParagraph()
                let header = parseTableRow(line)
                index += 2
                var rows: [[String]] = []
                var closed = false
                while index < lines.count {
                    let rowLine = lines[index]
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                    if rowTrimmed.isEmpty {
                        closed = true
                        index += 1
                        break
                    }
                    if MarkdownFence.opener(rowLine) != nil ||
                        isThematicBreak(rowTrimmed) ||
                        heading(rowTrimmed) != nil ||
                        rowTrimmed.hasPrefix(">") ||
                        listItem(rowTrimmed) != nil ||
                        rowTrimmed.hasPrefix("$$") ||
                        rowTrimmed.hasPrefix("\\[")
                    {
                        closed = true
                        break
                    }
                    guard rowTrimmed.contains("|") else {
                        closed = true
                        break
                    }
                    rows.append(parseTableRow(rowLine))
                    index += 1
                }
                emit(.table(header: header, rows: rows, isClosed: closed))
                continue
            }

            if MathFormatter.isStandaloneEquation(trimmed) {
                flushParagraph()
                var body: [Substring] = [line]
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty else { break }
                    guard MathFormatter.isStandaloneEquation(candidate) ||
                        candidate.hasPrefix("\\left(") || candidate.hasPrefix("\\right)") ||
                        candidate.hasPrefix("\\frac") || candidate.hasPrefix("=") ||
                        candidate.hasPrefix("+") || candidate.hasPrefix("-")
                    else { break }
                    body.append(lines[index])
                    index += 1
                }
                let rawCode = body.joined(separator: "\n")
                emit(.math(equation: MathFormatter.formatEquation(rawCode), raw: rawCode, isClosed: true))
                continue
            }

            paragraph.append(String(line))
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func extractEnvironmentName(_ line: String) -> String? {
        guard let start = line.range(of: "\\begin{")?.upperBound else { return nil }
        guard let end = line[start...].firstIndex(of: "}") else { return nil }
        return String(line[start ..< end])
    }

    private static let mathEnvironments: Set<String> = ["equation", "equation*", "align", "align*", "aligned", "gather", "gather*", "multline", "multline*", "matrix", "pmatrix", "bmatrix", "vmatrix", "Vmatrix", "cases"]

    private static func isMathEnvironment(_ name: String) -> Bool {
        return mathEnvironments.contains(name)
    }

    private static func parseTableRow(_ line: Substring) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") {
            trimmed.removeLast()
        }
        var cells: [String] = []
        var current = ""
        var isEscaped = false
        for char in trimmed {
            if isEscaped {
                if char == "|" {
                    current.append("|")
                } else {
                    current.append("\\")
                    current.append(char)
                }
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(char)
            }
        }
        if isEscaped {
            current.append("\\")
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isTableDelimiterRow(_ line: Substring) -> Bool {
        guard line.contains("|") else { return false }
        let cells = parseTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { isDelimiterCell($0) }
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var dashes = 0
        for (index, char) in trimmed.enumerated() {
            if char == "-" {
                dashes += 1
            } else if char == ":" {
                if index != 0 && index != trimmed.count - 1 {
                    return false
                }
            } else {
                return false
            }
        }
        return dashes >= 1
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
    private static let citationRegex = try? NSRegularExpression(
        pattern: #"(?<!\[|\`|\\)\[([1-9][0-9]?)\](?!\(|\`|\])"#
    )

    /// `.inlineOnlyPreservingWhitespace` is required: the default `.full` syntax
    /// collapses newlines and hard-wraps, which destroys the line structure of a
    /// paragraph that the block parser already decided to keep together.
    ///
    /// `returnPartiallyParsedIfPossible` plus the `??` fallback guarantee that a
    /// half-written emphasis run or a stray bracket from a partial stream renders
    /// as literal text rather than blanking the message.
    static func attributed(_ source: String, sources: [SearchResult]? = nil) -> AttributedString {
        let preparedMath = MathFormatter.formatText(source)
        let prepared = prepareCitations(preparedMath, sources: sources)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.allowsExtendedAttributes = true
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var attr = (try? AttributedString(markdown: prepared, options: options)) ?? AttributedString(source)
        for run in attr.runs {
            if var intent = run.inlinePresentationIntent, intent.contains(.code) {
                intent.remove(.code)
                attr[run.range].inlinePresentationIntent = intent.isEmpty ? nil : intent
                attr[run.range].font = .appMono(size: 15, relativeTo: .body)
                attr[run.range].backgroundColor = Color.secondary.opacity(0.12)
            }
        }
        return attr
    }

    /// Formats a standalone equation for rendering in a math block.
    static func attributedMath(_ equation: String) -> AttributedString {
        var attr = AttributedString(equation)
        attr.font = .appSans(size: 17, weight: .regular)
        return attr
    }

    /// Links `[n]` citation markers to their corresponding source URLs (R4.4).
    private static func prepareCitations(_ text: String, sources: [SearchResult]?) -> String {
        guard let sources, !sources.isEmpty else { return text }
        // Match [1], [2], etc. that are not already markdown links or code spans
        guard let regex = citationRegex else {
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
    private struct CacheKey: Hashable {
        let source: String
        let sourcesCount: Int
    }

    private static let limit = 240
    private static var storage: [CacheKey: [MarkdownBlock]] = [:]
    private static var order: [CacheKey] = []
    private static var head = 0

    static func blocks(for source: String, sources: [SearchResult]? = nil) -> [MarkdownBlock] {
        let key = CacheKey(source: source, sourcesCount: sources?.count ?? 0)
        if let cached = storage[key] {
            return cached
        }
        var parsed = MarkdownBlockParser.parse(source)
        for index in parsed.indices {
            parsed[index].precomputeAttributed(sources: sources)
        }
        storage[key] = parsed
        order.append(key)
        if order.count - head > limit {
            storage.removeValue(forKey: order[head])
            head += 1
            if head > limit {
                order.removeFirst(head)
                head = 0
            }
        }
        return parsed
    }

    /// Called when a conversation is closed (R2.6): the cache is per-message and
    /// there is no reason to hold another conversation's transcript in memory.
    static func clear() {
        storage.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        head = 0
    }
}

// MARK: - Views

/// Renders a single markdown block. Shared by `MarkdownBlocksView` (for committed messages)
/// and `StreamingMessageView` (for live in-flight streaming).
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    var sources: [SearchResult]?

    var body: some View {
        switch block.kind {
        case let .paragraph(text):
            Text(block.cachedAttributed ?? MarkdownInline.attributed(text, sources: sources))
                .font(.appSans(.body))
                .appLineSpacing(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .heading(level, text):
            Text(block.cachedAttributed ?? MarkdownInline.attributed(text, sources: sources))
                .font(headingFont(level))
                .appLineSpacing(headingTextStyle(level))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, headingTopPadding(level, isFirst: block.id == 0))
                .padding(.bottom, headingBottomPadding(level))
                .accessibilityAddTraits(.isHeader)

        case let .code(language, code, isClosed):
            CodeBlockView(language: language, code: code, isClosed: isClosed)

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                Text(block.cachedAttributed ?? MarkdownInline.attributed(text))
                    .font(.appSans(.body))
                    .appLineSpacing(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    let attributedItem = {
                        if let list = block.cachedListAttributed, offset < list.count {
                            return list[offset]
                        }
                        return MarkdownInline.attributed(item)
                    }()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(start + offset)." : "•")
                            .font(.appSans(.body))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(attributedItem)
                            .font(.appSans(.body))
                            .appLineSpacing(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .table(header, rows, isClosed):
            TableView(
                header: header,
                rows: rows,
                isClosed: isClosed,
                headerAttributed: block.cachedTableHeaderAttributed,
                rowsAttributed: block.cachedTableRowsAttributed,
                sources: sources
            )

        case let .math(equation, raw, isClosed):
            MathBlockView(
                equation: equation,
                raw: raw,
                isClosed: isClosed,
                cachedAttributed: block.cachedAttributed
            )

        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .appSans(.title2, weight: .bold)
        case 2: return .appSans(.title3, weight: .semibold)
        case 3: return .appSans(.headline, weight: .semibold)
        default: return .appSans(.subheadline, weight: .semibold)
        }
    }

    private func headingTextStyle(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }

    private func headingTopPadding(_ level: Int, isFirst: Bool) -> CGFloat {
        guard !isFirst else { return 0 }
        switch level {
        case 1: return 16
        case 2: return 12
        case 3: return 8
        default: return 6
        }
    }

    private func headingBottomPadding(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 2
        case 2: return 1
        default: return 0
        }
    }
}

/// Blocks are parsed once and cached per message. This view only renders
/// the cached result, so scrolling through a long transcript does not re-parse.
struct MarkdownBlocksView: View, Equatable {
    let source: String
    var sources: [SearchResult]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownCache.blocks(for: source, sources: sources)) { block in
                MarkdownBlockView(block: block, sources: sources)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Fenced code lives in its own horizontal `ScrollView` so a single long line
/// never widens the transcript and makes the whole page scroll sideways.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    let isClosed: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.appSans(.caption2, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
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
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.appSans(.caption2))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(.appMono(.footnote))
                    .lineSpacing(3.5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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

/// Tables live in a horizontal `ScrollView` with a `Grid` to prevent wide tables
/// from blowing out horizontal transcript layout.
private struct TableView: View {
    let header: [String]
    let rows: [[String]]
    let isClosed: Bool
    var headerAttributed: [AttributedString]?
    var rowsAttributed: [[AttributedString]]?
    var sources: [SearchResult]?

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { offset, title in
                            let text = headerAttributed.flatMap { offset < $0.count ? $0[offset] : nil }
                                ?? MarkdownInline.attributed(title, sources: sources)
                            Text(text.characters.isEmpty ? AttributedString(" ") : text)
                                .font(.appSans(.body, weight: .bold))
                                .appLineSpacing(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                            let text = rowsAttributed.flatMap { rows in
                                rowIndex < rows.count && colIndex < rows[rowIndex].count
                                    ? rows[rowIndex][colIndex]
                                    : nil
                            } ?? MarkdownInline.attributed(cell, sources: sources)
                            Text(text.characters.isEmpty ? AttributedString(" ") : text)
                                .font(.appSans(.body))
                                .appLineSpacing(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Divider()
                            .opacity(0.4)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            if !isClosed {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(height: 2)
            }
        }
        .accessibilityLabel("Table with \(header.count) columns and \(rows.count) rows")
    }
}
