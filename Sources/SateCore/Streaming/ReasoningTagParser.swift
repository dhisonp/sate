import Foundation

/// Streaming parser and extractor for in-band reasoning tags (`<think>...</think>`
/// and `<thought>...</thought>`).
///
/// Many open-weights reasoning models (DeepSeek-R1, Qwen 3.8, Gemma 4) emit their
/// thought traces inside `<think>` tags within the regular `content` stream rather
/// than using provider-specific `reasoning_content` fields.
///
/// This parser processes deltas incrementally across arbitrary chunk boundaries,
/// routing thoughts to `reasoning` and the clean response to `text`.
public struct ReasoningTagParser: Sendable {
    private enum State {
        case text
        case thinking(tag: String)
    }

    private var state: State = .text
    private var buffer: String = ""

    public init() {}

    /// Processes text incrementally across chunk boundaries, splitting out
    /// reasoning tags and buffering partial opening/closing tags across chunk boundaries.
    public mutating func process(text: String) -> (text: String, reasoning: String) {
        guard !text.isEmpty || !buffer.isEmpty else { return ("", "") }

        var input = buffer + text
        buffer.removeAll(keepingCapacity: true)

        var outText = ""
        var outReasoning = ""

        while !input.isEmpty {
            switch state {
            case .text:
                if let openMatch = findOpenTag(in: input) {
                    outText += input[..<openMatch.range.lowerBound]
                    state = .thinking(tag: openMatch.tag)
                    input = String(input[openMatch.range.upperBound...])
                } else {
                    let (safeText, candidate) = splitCandidatePrefix(input, prefixes: Self.openTagPrefixes)
                    outText += safeText
                    buffer = candidate
                    return (outText, outReasoning)
                }

            case let .thinking(tag):
                let closeTag = "</\(tag)>"
                if let closeRange = input.range(of: closeTag, options: .caseInsensitive) {
                    outReasoning += input[..<closeRange.lowerBound]
                    state = .text
                    var remaining = input[closeRange.upperBound...]
                    // Strip one immediate newline following </think> if present
                    if remaining.hasPrefix("\n") {
                        remaining = remaining.dropFirst()
                    } else if remaining.hasPrefix("\r\n") {
                        remaining = remaining.dropFirst(2)
                    }
                    input = String(remaining)
                } else {
                    let (safeReasoning, candidate) = splitCandidatePrefix(
                        input, prefixes: Self.closeTagPrefixesByTag[tag] ?? []
                    )
                    outReasoning += safeReasoning
                    buffer = candidate
                    return (outText, outReasoning)
                }
            }
        }

        return (outText, outReasoning)
    }

    /// Drains any remaining buffered partial tag at the end of the stream.
    public mutating func finish() -> (text: String, reasoning: String) {
        guard !buffer.isEmpty else { return ("", "") }
        let trailing = buffer
        buffer.removeAll()
        switch state {
        case .text:
            return (trailing, "")
        case .thinking:
            return ("", trailing)
        }
    }

    // MARK: - Static Helpers

    /// Extracts clean text and reasoning from a complete string.
    public static func extract(from text: String) -> (text: String, reasoning: String?) {
        var parser = ReasoningTagParser()
        let (pText, pReasoning) = parser.process(text: text)
        let (fText, fReasoning) = parser.finish()
        let combinedText = (pText + fText).trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedReasoning = (pReasoning + fReasoning).trimmingCharacters(in: .whitespacesAndNewlines)
        return (combinedText, combinedReasoning.isEmpty ? nil : combinedReasoning)
    }

    /// Strips `<think>...</think>` and `<thought>...</thought>` tags and their contents from a string.
    public static func strip(from text: String) -> String {
        extract(from: text).text
    }

    // MARK: - Tag Scanning Internals

    private struct TagMatch {
        var tag: String
        var range: Range<String.Index>
    }

    private static let recognizedTags = ["think", "thought"]

    private static let openTagPrefixes: [String] = {
        var prefixes: [String] = []
        for tag in recognizedTags {
            let full = "<\(tag)>"
            for len in 1 ..< full.count {
                prefixes.append(String(full.prefix(len)))
            }
        }
        return prefixes
    }()

    private static let closeTagPrefixesByTag: [String: [String]] = {
        var dict: [String: [String]] = [:]
        for tag in recognizedTags {
            let full = "</\(tag)>"
            var prefixes: [String] = []
            for len in 1 ..< full.count {
                prefixes.append(String(full.prefix(len)))
            }
            dict[tag] = prefixes
        }
        return dict
    }()

    private func findOpenTag(in text: String) -> TagMatch? {
        var earliest: TagMatch?
        for tag in Self.recognizedTags {
            let open = "<\(tag)>"
            if let range = text.range(of: open, options: .caseInsensitive) {
                if let current = earliest {
                    if range.lowerBound < current.range.lowerBound {
                        earliest = TagMatch(tag: tag, range: range)
                    }
                } else {
                    earliest = TagMatch(tag: tag, range: range)
                }
            }
        }
        return earliest
    }

    private func splitCandidatePrefix(_ text: String, prefixes: [String]) -> (safe: String, candidate: String) {
        let maxCandidateLength = prefixes.map(\.count).max() ?? 10
        let checkLength = min(text.count, maxCandidateLength)
        guard checkLength > 0 else { return (text, "") }
        let suffixStart = text.index(text.endIndex, offsetBy: -checkLength)
        let suffix = String(text[suffixStart...])

        for len in (1 ... suffix.count).reversed() {
            let tail = String(suffix.suffix(len))
            if prefixes.contains(where: { $0.caseInsensitiveCompare(tail) == .orderedSame }) {
                let splitIndex = text.index(text.endIndex, offsetBy: -len)
                return (String(text[..<splitIndex]), tail)
            }
        }

        return (text, "")
    }
}
