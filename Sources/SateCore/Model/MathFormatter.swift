import Foundation

/// Supports inline math (`$ ... $`, `\( ... \)`), display math (`$$ ... $$`, `\[ ... \]`),
/// LaTeX environments (`\begin{equation}`, `\begin{align}`, `\begin{matrix}`, `\begin{cases}`),
/// and un-delimited mathematical expressions. Foundation-only, zero dependencies.
public enum MathFormatter: Sendable {
    private static let envWrappers = [
        "equation", "equation*", "align", "align*", "aligned",
        "gather", "gather*", "multline", "multline*",
    ]

    private static let standaloneKeywords = [
        "\\text{", "\\frac{", "\\sqrt", "\\left(", "\\sum",
        "\\int", "\\mathbf{", "\\mathcal{", "\\alpha", "\\beta", "\\partial", "\\begin{",
    ]

    private static let displayRegex = try! NSRegularExpression(
        pattern: #"\$\$(.+?)\$\$"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let bracketRegex = try! NSRegularExpression(
        pattern: #"\\\[(.+?)\\\]"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let envRegex = try! NSRegularExpression(
        pattern: #"\\begin\{(equation\*?|align\*?|aligned|gather\*?|matrix|pmatrix|bmatrix|vmatrix|Vmatrix|cases)\}(.+?)\\end\{\1\}"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let parenRegex = try! NSRegularExpression(
        pattern: #"\\\((.+?)\\\)"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let dollarRegex = try! NSRegularExpression(
        pattern: #"(?<!\\|\$)\$(?!\s|\$)([^\$\n]+?)(?<!\s|\$)\$(?!\$)"#
    )

    // MARK: - Public API

    /// Formats a complete LaTeX mathematical expression into Unicode notation.
    public static func formatEquation(_ latex: String) -> String {
        var clean = latex.trimmingCharacters(in: .whitespacesAndNewlines)

        if clean.hasPrefix("$$") && clean.hasSuffix("$$") && clean.count >= 4 {
            clean = String(clean.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix("\\[") && clean.hasSuffix("\\]") && clean.count >= 4 {
            clean = String(clean.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix("\\(") && clean.hasSuffix("\\)") && clean.count >= 4 {
            clean = String(clean.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix("$") && clean.hasSuffix("$") && clean.count >= 2 {
            clean = String(clean.dropFirst(1).dropLast(1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for env in envWrappers {
            let begin = "\\begin{\(env)}"
            let end = "\\end{\(env)}"
            if clean.hasPrefix(begin) && clean.hasSuffix(end) && clean.count >= begin.count + end.count {
                clean = String(clean.dropFirst(begin.count).dropLast(end.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return MathParser.parse(clean)
    }

    /// Formats math expressions inside mixed markdown/text (handling $$, \[\], \(\), $, \begin{}, and raw LaTeX).
    public static func formatText(_ text: String) -> String {
        var result = text

        result = MathParser.replaceMatches(in: result, regex: displayRegex) { formatEquation($0) }
        result = MathParser.replaceMatches(in: result, regex: bracketRegex) { formatEquation($0) }
        result = MathParser.replaceMatches(in: result, regex: envRegex, groupIndex: 0) { formatEquation($0) }
        result = MathParser.replaceMatches(in: result, regex: parenRegex) { formatEquation($0) }
        
        result = MathParser.replaceMatches(in: result, regex: dollarRegex) { match in
            if match.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) {
                return "$\(match)$"
            }
            return formatEquation(match)
        }

        return MathParser.formatUnDelimitedMath(result)
    }

    /// Checks if a string or block of lines represents a standalone mathematical equation.
    public static func isStandaloneEquation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if (trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$")) ||
            (trimmed.hasPrefix("\\[") && trimmed.hasSuffix("\\]"))
        {
            return true
        }

        if trimmed.hasPrefix("\\begin{") {
            let mathEnvs = ["equation", "align", "aligned", "gather", "matrix", "pmatrix", "bmatrix", "cases"]
            for env in mathEnvs where trimmed.hasPrefix("\\begin{\(env)}") || trimmed.hasPrefix("\\begin{\(env)*}") {
                return true
            }
        }

        let lines = trimmed.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }

        var count = 0
        for line in lines where standaloneKeywords.contains(where: { line.contains($0) }) {
            count += 1
        }

        if count > 0 && count >= lines.count {
            let commonProse = ["The", "This", "That", "When", "Where", "Because", "However", "Note", "If"]
            let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." }).map(String.init)
            let proseCount = words.filter { commonProse.contains($0) }.count
            let hasMathOp = trimmed.contains("=") || trimmed.contains("\\frac") ||
                trimmed.contains("\\sum") || trimmed.contains("\\int")
            if proseCount == 0 && hasMathOp {
                return true
            }
        }

        return false
    }

    // MARK: - Character Mappings

    public static func canConvertToSuperscript(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { MathTables.superscriptMap[$0] != nil }
    }

    public static func canConvertToSubscript(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { MathTables.subscriptMap[$0] != nil }
    }

    public static func toSuperscript(_ text: String) -> String {
        String(text.map { MathTables.superscriptMap[$0] ?? $0 })
    }

    public static func toSubscript(_ text: String) -> String {
        String(text.map { MathTables.subscriptMap[$0] ?? $0 })
    }

    static func toBlackboardBold(_ text: String) -> String {
        String(text.map { MathTables.blackboardBoldMap[$0] ?? $0 })
    }

    static func toCalligraphic(_ text: String) -> String {
        String(text.map { MathTables.calligraphicMap[$0] ?? $0 })
    }
}

// MARK: - Parser & Format Engine

private enum MathParser {
    static func parse(_ input: String) -> String {
        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            let char = input[index]

            if char == "\\" {
                let (formatted, nextIdx) = parseCommand(input, startingAt: index)
                output += formatted
                index = nextIdx
                continue
            }

            if char == "^" || char == "_" {
                let isSup = char == "^"
                let nextIdx = input.index(after: index)
                if nextIdx < input.endIndex {
                    let arg = extractArgument(from: input, startingAt: nextIdx)
                    let formattedArg = parse(arg.content)
                    if isSup {
                        output += MathFormatter.canConvertToSuperscript(formattedArg)
                            ? MathFormatter.toSuperscript(formattedArg) : "^{\(formattedArg)}"
                    } else {
                        output += MathFormatter.canConvertToSubscript(formattedArg)
                            ? MathFormatter.toSubscript(formattedArg) : "_{\(formattedArg)}"
                    }
                    index = arg.nextIndex
                    continue
                }
            }

            if char == "{" || char == "}" {
                index = input.index(after: index)
                continue
            }

            if char == "=" {
                if !output.hasSuffix(" ") {
                    output += " "
                }
                output += "= "
                index = input.index(after: index)
                while index < input.endIndex && input[index] == " " {
                    index = input.index(after: index)
                }
                continue
            }

            output.append(char)
            index = input.index(after: index)
        }

        return cleanSpaces(output)
    }

    static func parseCommand(
        _ input: String,
        startingAt start: String.Index
    ) -> (formatted: String, nextIndex: String.Index) {
        guard input[start] == "\\" else { return ("", start) }
        let afterBackslash = input.index(after: start)
        guard afterBackslash < input.endIndex else { return ("\\", input.endIndex) }

        let nextChar = input[afterBackslash]
        if let esc = handleEscaped(nextChar) {
            return (esc, input.index(after: afterBackslash))
        }

        var cmdEnd = afterBackslash
        while cmdEnd < input.endIndex, input[cmdEnd].isLetter {
            cmdEnd = input.index(after: cmdEnd)
        }

        let cmdName = String(input[afterBackslash ..< cmdEnd])
        let currentIndex = cmdEnd

        if let result = dispatchCommand(cmdName, input: input, currentIndex: currentIndex) {
            return result
        }

        if MathTables.mathFunctions.contains(cmdName) {
            var parseIdx = currentIndex
            while parseIdx < input.endIndex, input[parseIdx] == " " {
                parseIdx = input.index(after: parseIdx)
            }
            if parseIdx < input.endIndex, input[parseIdx] == "(" || input[parseIdx] == "[" {
                return (cmdName, parseIdx)
            }
            return (cmdName + " ", parseIdx)
        }

        let fullCmd = "\\" + cmdName
        if let symbol = MathTables.latexSymbols[fullCmd] {
            return (isBinaryOrRelation(symbol) ? " \(symbol) " : symbol, currentIndex)
        }

        return (cmdName, currentIndex)
    }

    private static func handleEscaped(_ nextChar: Character) -> String? {
        if nextChar == "{" || nextChar == "}" || nextChar == "%" || nextChar == "$" ||
            nextChar == "&" || nextChar == "#" || nextChar == "_"
        {
            return String(nextChar)
        }
        if nextChar == "\\" {
            return "\n"
        }
        if nextChar == "," || nextChar == " " || nextChar == ":" || nextChar == ";" {
            return " "
        }
        if nextChar == "!" {
            return ""
        }
        return nil
    }

    private static func dispatchCommand(
        _ cmdName: String,
        input: String,
        currentIndex: String.Index
    ) -> (formatted: String, nextIndex: String.Index)? {
        if cmdName == "text" || cmdName == "mathrm" || cmdName == "operatorname" || cmdName == "operatorname*" {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            return (arg.content, arg.nextIndex)
        }
        if cmdName == "mathbf" || cmdName == "bm" {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            return (parse(arg.content), arg.nextIndex)
        }
        if cmdName == "mathbb" {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            return (MathFormatter.toBlackboardBold(arg.content), arg.nextIndex)
        }
        if cmdName == "mathcal" || cmdName == "mathscr" {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            return (MathFormatter.toCalligraphic(arg.content), arg.nextIndex)
        }
        if cmdName == "frac" || cmdName == "dfrac" || cmdName == "tfrac" || cmdName == "cfrac" {
            let numArg = extractArgument(from: input, startingAt: currentIndex)
            let denArg = extractArgument(from: input, startingAt: numArg.nextIndex)
            let num = parse(numArg.content)
            let den = parse(denArg.content)
            return (formatFraction(numerator: num, denominator: den), denArg.nextIndex)
        }
        if cmdName == "sqrt" {
            return parseSqrt(input: input, currentIndex: currentIndex)
        }
        if cmdName == "binom" {
            let nArg = extractArgument(from: input, startingAt: currentIndex)
            let kArg = extractArgument(from: input, startingAt: nArg.nextIndex)
            return ("(\(parse(nArg.content)) choose \(parse(kArg.content)))", kArg.nextIndex)
        }
        if let accent = MathTables.accentSymbols[cmdName] {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            return (parse(arg.content) + accent, arg.nextIndex)
        }
        if cmdName == "left" || cmdName == "right" {
            return parseDelimiter(input: input, currentIndex: currentIndex)
        }
        if cmdName == "begin" {
            let envArg = extractArgument(from: input, startingAt: currentIndex)
            let envName = envArg.content.trimmingCharacters(in: .whitespaces)
            let endPattern = "\\end{\(envName)}"
            if let endRange = input[envArg.nextIndex...].range(of: endPattern) {
                let body = String(input[envArg.nextIndex ..< endRange.lowerBound])
                return (MathEnvironmentFormatter.format(name: envName, body: body), endRange.upperBound)
            }
        }
        if cmdName == "quad" {
            return ("  ", currentIndex)
        }
        if cmdName == "qquad" {
            return ("    ", currentIndex)
        }
        return nil
    }

    private static func parseSqrt(
        input: String,
        currentIndex: String.Index
    ) -> (formatted: String, nextIndex: String.Index) {
        var rootIndex: String?
        var parseIdx = currentIndex
        while parseIdx < input.endIndex, input[parseIdx] == " " {
            parseIdx = input.index(after: parseIdx)
        }
        if parseIdx < input.endIndex, input[parseIdx] == "[" {
            let bracketArg = extractBracketArgument(from: input, startingAt: parseIdx)
            rootIndex = parse(bracketArg.content)
            parseIdx = bracketArg.nextIndex
        }
        let radicandArg = extractArgument(from: input, startingAt: parseIdx)
        let radicand = parse(radicandArg.content)
        let formatted: String
        if let rootIndex {
            if rootIndex == "3" {
                formatted = "∛" + wrapIfNeeded(radicand)
            } else if rootIndex == "4" {
                formatted = "∜" + wrapIfNeeded(radicand)
            } else {
                let sup = MathFormatter.canConvertToSuperscript(rootIndex)
                    ? MathFormatter.toSuperscript(rootIndex) : rootIndex
                formatted = "\(sup)√" + wrapIfNeeded(radicand)
            }
        } else {
            formatted = "√" + wrapIfNeeded(radicand)
        }
        return (formatted, radicandArg.nextIndex)
    }

    private static func parseDelimiter(
        input: String,
        currentIndex: String.Index
    ) -> (formatted: String, nextIndex: String.Index) {
        var delimIdx = currentIndex
        while delimIdx < input.endIndex, input[delimIdx] == " " {
            delimIdx = input.index(after: delimIdx)
        }
        guard delimIdx < input.endIndex else { return ("", delimIdx) }
        let delimChar = input[delimIdx]
        if delimChar == "\\" {
            let delimCmd = parseCommand(input, startingAt: delimIdx)
            return (delimCmd.formatted, delimCmd.nextIndex)
        }
        if delimChar == "." {
            return ("", input.index(after: delimIdx))
        }
        return (String(delimChar), input.index(after: delimIdx))
    }

    static func extractArgument(
        from string: String,
        startingAt index: String.Index
    ) -> (content: String, nextIndex: String.Index) {
        var idx = index
        while idx < string.endIndex, string[idx] == " " {
            idx = string.index(after: idx)
        }
        guard idx < string.endIndex else { return ("", string.endIndex) }

        if string[idx] == "{" {
            var depth = 1
            let start = string.index(after: idx)
            var current = start
            while current < string.endIndex {
                if string[current] == "{" {
                    depth += 1
                } else if string[current] == "}" {
                    depth -= 1
                    if depth == 0 {
                        return (String(string[start ..< current]), string.index(after: current))
                    }
                }
                current = string.index(after: current)
            }
            return (String(string[start...]), string.endIndex)
        }

        if string[idx] == "\\" {
            var end = string.index(after: idx)
            while end < string.endIndex, string[end].isLetter {
                end = string.index(after: end)
            }
            return (String(string[idx ..< end]), end)
        }

        return (String(string[idx]), string.index(after: idx))
    }

    private static func extractBracketArgument(
        from string: String,
        startingAt index: String.Index
    ) -> (content: String, nextIndex: String.Index) {
        guard index < string.endIndex, string[index] == "[" else { return ("", index) }
        let start = string.index(after: index)
        var current = start
        while current < string.endIndex {
            if string[current] == "]" {
                return (String(string[start ..< current]), string.index(after: current))
            }
            current = string.index(after: current)
        }
        return (String(string[start...]), string.endIndex)
    }

    private static func formatFraction(numerator: String, denominator: String) -> String {
        let num = numerator.trimmingCharacters(in: .whitespaces)
        let den = denominator.trimmingCharacters(in: .whitespaces)
        let numNeedsParens = num.contains(" ") || num.contains("+") || num.contains("-") || num.contains("/")
        let denNeedsParens = den.contains(" ") || den.contains("+") || den.contains("-") || den.contains("/")
        return "\(numNeedsParens ? "(\(num))" : num) / \(denNeedsParens ? "(\(den))" : den)"
    }

    static func wrapIfNeeded(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if (trimmed.count <= 2 && !trimmed.contains(" ")) || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) {
            return trimmed
        }
        return "(\(trimmed))"
    }

    static func formatUnDelimitedMath(_ text: String) -> String {
        guard text.contains("\\") || text.contains("_") || text.contains("^") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { lineSub in
            let line = String(lineSub)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("\\text{") || trimmed.contains("\\frac{") || trimmed.contains("\\sqrt") ||
                trimmed.contains("\\left(") || trimmed.contains("\\right)") || trimmed.contains("\\sum") ||
                trimmed.contains("\\alpha") || trimmed.contains("\\beta") || trimmed.contains("\\partial")
            {
                return parse(line)
            } else if trimmed.contains("_") || trimmed.contains("^") {
                return formatInlineSubscriptsAndSuperscripts(line)
            }
            return line
        }.joined(separator: "\n")
    }

    private static let subRegex = try! NSRegularExpression(pattern: #"([a-zA-Z])_([a-zA-Z0-9])\b"#)
    private static let supRegex = try! NSRegularExpression(pattern: #"([a-zA-Z0-9])\^([a-zA-Z0-9])\b"#)

    private static func formatInlineSubscriptsAndSuperscripts(_ line: String) -> String {
        var result = line
        result = replaceMatches(in: result, regex: subRegex, groupIndex: 0) { match in
            let base = match.prefix(1)
            let sub = match.suffix(1)
            return "\(base)\(MathFormatter.toSubscript(String(sub)))"
        }
        result = replaceMatches(in: result, regex: supRegex, groupIndex: 0) { match in
            let parts = match.split(separator: "^")
            if parts.count == 2 {
                return "\(parts[0])\(MathFormatter.toSuperscript(String(parts[1])))"
            }
            return match
        }
        return result
    }

    static func replaceMatches(
        in text: String,
        regex: NSRegularExpression,
        groupIndex: Int = 1,
        transform: (String) -> String
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastIndex = text.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  let targetRange = Range(match.range(at: groupIndex), in: text) else { continue }
            result += text[lastIndex ..< fullRange.lowerBound]
            result += transform(String(text[targetRange]))
            lastIndex = fullRange.upperBound
        }
        result += text[lastIndex...]
        return result
    }

    private static func cleanSpaces(_ text: String) -> String {
        var result = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        result = result.replacingOccurrences(of: " ( ", with: " (")
        result = result.replacingOccurrences(of: " ) ", with: ") ")
        result = result.replacingOccurrences(of: "( ", with: "(")
        result = result.replacingOccurrences(of: " )", with: ")")
        result = result.replacingOccurrences(of: " ,", with: ",")
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isBinaryOrRelation(_ symbol: String) -> Bool {
        let ops = [
            "±", "∓", "×", "÷", "·", "⊕", "⊗", "⊙", "≤", "≥", "≠", "≈",
            "≡", "∼", "∝", "∈", "∉", "⊂", "⊃", "⊆", "⊇", "∩", "∪", "∧",
            "∨", "→", "←", "↔", "⇒", "⇐", "⇔", "↦",
        ]
        return ops.contains(symbol)
    }
}

// MARK: - Environment Formatter

private enum MathEnvironmentFormatter {
    static func format(name: String, body: String) -> String {
        let rows = body.components(separatedBy: "\\\\").map { row in
            row.components(separatedBy: "&").map { cell in
                MathParser.parse(cell.trimmingCharacters(in: .whitespaces))
            }
        }

        if name == "pmatrix" {
            return formatMatrix(rows: rows, openBracket: "(", closeBracket: ")")
        }
        if name == "bmatrix" {
            return formatMatrix(rows: rows, openBracket: "[", closeBracket: "]")
        }
        if name == "matrix" {
            return formatMatrix(rows: rows, openBracket: "", closeBracket: "")
        }
        if name == "vmatrix" || name == "Vmatrix" {
            return formatMatrix(rows: rows, openBracket: "|", closeBracket: "|")
        }
        if name == "cases" {
            return formatCases(rows: rows)
        }
        return rows.map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    private static func formatMatrix(rows: [[String]], openBracket: String, closeBracket: String) -> String {
        guard !rows.isEmpty else { return "" }
        if rows.count == 1 {
            return "\(openBracket) \(rows[0].joined(separator: "  ")) \(closeBracket)"
        }
        return rows.enumerated().map { index, row in
            let rowStr = row.joined(separator: "  ")
            let open = index == 0 ? (openBracket.isEmpty ? " " : "⎡") :
                (index == rows.count - 1 ? (openBracket.isEmpty ? " " : "⎣") : (openBracket.isEmpty ? " " : "⎢"))
            let close = index == 0 ? (closeBracket.isEmpty ? " " : "⎤") :
                (index == rows.count - 1 ? (closeBracket.isEmpty ? " " : "⎦") : (closeBracket.isEmpty ? " " : "⎥"))
            return "\(open) \(rowStr) \(close)"
        }.joined(separator: "\n")
    }

    private static func formatCases(rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        return rows.enumerated().map { index, row in
            let brace = index == 0 ? "⎧" : (index == rows.count - 1 ? "⎩" : "⎪")
            return "\(brace) \(row.joined(separator: "   "))"
        }.joined(separator: "\n")
    }
}
