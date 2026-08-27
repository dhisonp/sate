import Foundation

/// Formats LaTeX mathematical expressions and notation into clean, legible Unicode math.
///
/// Supports inline math (`$ ... $`, `\( ... \)`), display math (`$$ ... $$`, `\[ ... \]`),
/// LaTeX environments (`\begin{equation}`, `\begin{align}`, `\begin{matrix}`, `\begin{cases}`),
/// and un-delimited mathematical expressions. Foundation-only, zero dependencies.
public enum MathFormatter: Sendable {
    // MARK: - Public API

    /// Formats a complete LaTeX mathematical expression into Unicode notation.
    public static func formatEquation(_ latex: String) -> String {
        var clean = latex.trimmingCharacters(in: .whitespacesAndNewlines)

        // Unwrap block delimiters if present
        if clean.hasPrefix("$$") && clean.hasSuffix("$$") && clean.count >= 4 {
            clean = String(clean.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix("\\[") && clean.hasSuffix("\\]") && clean.count >= 4 {
            clean = String(clean.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix("\\(") && clean.hasSuffix("\\)") && clean.count >= 4 {
            clean = String(clean.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix("$") && clean.hasSuffix("$") && clean.count >= 2 {
            clean = String(clean.dropFirst(1).dropLast(1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Unwrap \begin{equation} ... \end{equation} or similar wrappers
        for env in ["equation", "equation*", "align", "align*", "aligned", "gather", "gather*", "multline", "multline*"] {
            let begin = "\\begin{\(env)}"
            let end = "\\end{\(env)}"
            if clean.hasPrefix(begin) && clean.hasSuffix(end) && clean.count >= begin.count + end.count {
                clean = String(clean.dropFirst(begin.count).dropLast(end.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return parseExpression(clean)
    }

    /// Formats math expressions inside mixed markdown/text (handling $$, \[\], \(\), $, \begin{}, and raw LaTeX).
    public static func formatText(_ text: String) -> String {
        var result = text

        // 1. Display math blocks: $$ ... $$
        if let displayRegex = try? NSRegularExpression(pattern: #"\$\$(.+?)\$\$"#, options: [.dotMatchesLineSeparators]) {
            result = replaceMatches(in: result, regex: displayRegex) { formatEquation($0) }
        }

        // 2. Display math blocks: \[ ... \]
        if let bracketRegex = try? NSRegularExpression(pattern: #"\\\[(.+?)\\\]"#, options: [.dotMatchesLineSeparators]) {
            result = replaceMatches(in: result, regex: bracketRegex) { formatEquation($0) }
        }

        // 3. LaTeX environments: \begin{env} ... \end{env}
        if let envRegex = try? NSRegularExpression(
            pattern: #"\\begin\{(equation|equation\*|align|align\*|aligned|gather|gather\*|matrix|pmatrix|bmatrix|vmatrix|Vmatrix|cases)\}(.+?)\\end\{\1\}"#,
            options: [.dotMatchesLineSeparators]
        ) {
            result = replaceMatches(in: result, regex: envRegex, groupIndex: 0) { formatEquation($0) }
        }

        // 4. Inline math: \( ... \)
        if let parenRegex = try? NSRegularExpression(pattern: #"\\\((.+?)\\\)"#, options: [.dotMatchesLineSeparators]) {
            result = replaceMatches(in: result, regex: parenRegex) { formatEquation($0) }
        }

        // 5. Inline math: $ ... $ (avoiding currency amounts like $50 or $100)
        if let dollarRegex = try? NSRegularExpression(pattern: #"(?<!\\|\$)\$(?!\s|\$)([^\$\n]+?)(?<!\s|\$)\$(?!\$)"#) {
            result = replaceMatches(in: result, regex: dollarRegex) { match in
                // Only treat as math if it contains math characters or no currency amounts
                if match.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) {
                    return "$\(match)$"
                }
                return formatEquation(match)
            }
        }

        // 6. Handle un-delimited LaTeX lines/expressions
        result = formatUnDelimitedMath(result)

        return result
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
            for env in ["equation", "equation*", "align", "align*", "aligned", "gather", "gather*", "matrix", "pmatrix", "bmatrix", "cases"] {
                if trimmed.hasPrefix("\\begin{\(env)}") {
                    return true
                }
            }
        }

        // Check for un-delimited math equation lines
        let lines = trimmed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }

        var mathIndicatorCount = 0
        for line in lines {
            if line.contains("\\text{") || line.contains("\\frac{") || line.contains("\\sqrt") ||
                line.contains("\\left(") || line.contains("\\sum") || line.contains("\\int") ||
                line.contains("\\mathbf{") || line.contains("\\mathcal{") || line.contains("\\alpha") ||
                line.contains("\\beta") || line.contains("\\partial") || line.contains("\\begin{")
            {
                mathIndicatorCount += 1
            }
        }

        if mathIndicatorCount > 0 && mathIndicatorCount >= lines.count {
            let lettersOnly = trimmed.filter { $0.isLetter }
            let commonProseWords = ["The", "This", "That", "When", "Where", "Because", "However", "Therefore", "Note", "In", "On", "If"]
            let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." }).map(String.init)
            let proseWordCount = words.filter { commonProseWords.contains($0) }.count
            if proseWordCount == 0 && (trimmed.contains("=") || trimmed.contains("\\frac") || trimmed.contains("\\sum") || trimmed.contains("\\int") || lettersOnly.count < 80) {
                return true
            }
        }

        return false
    }

    // MARK: - Core Parser

    private static func parseExpression(_ input: String) -> String {
        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            let char = input[index]

            if char == "\\" {
                let commandResult = parseCommand(input, startingAt: index)
                output += commandResult.formatted
                index = commandResult.nextIndex
                continue
            }

            if char == "^" {
                let nextIdx = input.index(after: index)
                if nextIdx < input.endIndex {
                    let arg = extractArgument(from: input, startingAt: nextIdx)
                    let formattedArg = parseExpression(arg.content)
                    if canConvertToSuperscript(formattedArg) {
                        output += toSuperscript(formattedArg)
                    } else {
                        output += "^{\(formattedArg)}"
                    }
                    index = arg.nextIndex
                    continue
                }
            }

            if char == "_" {
                let nextIdx = input.index(after: index)
                if nextIdx < input.endIndex {
                    let arg = extractArgument(from: input, startingAt: nextIdx)
                    let formattedArg = parseExpression(arg.content)
                    if canConvertToSubscript(formattedArg) {
                        output += toSubscript(formattedArg)
                    } else {
                        output += "_{\(formattedArg)}"
                    }
                    index = arg.nextIndex
                    continue
                }
            }

            if char == "{" || char == "}" {
                index = input.index(after: index)
                continue
            }

            // Clean spacing for binary operators
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

        // Clean redundant spaces
        return cleanSpaces(output)
    }

    private static func parseCommand(_ input: String, startingAt start: String.Index) -> (formatted: String, nextIndex: String.Index) {
        guard input[start] == "\\" else {
            return ("", start)
        }

        let afterBackslash = input.index(after: start)
        guard afterBackslash < input.endIndex else {
            return ("\\", input.endIndex)
        }

        let nextChar = input[afterBackslash]

        // 1. Escaped symbols
        if nextChar == "{" || nextChar == "}" || nextChar == "%" || nextChar == "$" ||
            nextChar == "&" || nextChar == "#" || nextChar == "_"
        {
            return (String(nextChar), input.index(after: afterBackslash))
        }
        if nextChar == "\\" {
            // Newline in LaTeX
            return ("\n", input.index(after: afterBackslash))
        }
        if nextChar == "," || nextChar == " " {
            return (" ", input.index(after: afterBackslash))
        }
        if nextChar == ":" || nextChar == ";" {
            return (" ", input.index(after: afterBackslash))
        }
        if nextChar == "!" {
            return ("", input.index(after: afterBackslash))
        }

        // 2. Command name (letters)
        var cmdEnd = afterBackslash
        while cmdEnd < input.endIndex && input[cmdEnd].isLetter {
            cmdEnd = input.index(after: cmdEnd)
        }

        let cmdName = String(input[afterBackslash ..< cmdEnd])
        let currentIndex = cmdEnd

        // 3. Dispatch known commands

        // Text and font styles
        if cmdName == "text" || cmdName == "mathrm" || cmdName == "operatorname" || cmdName == "operatorname*" {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            return (arg.content, arg.nextIndex)
        }

        if cmdName == "mathbf" || cmdName == "bm" {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            let formatted = parseExpression(arg.content)
            return (formatted, arg.nextIndex)
        }

        if cmdName == "mathbb" {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            let bb = toBlackboardBold(arg.content)
            return (bb, arg.nextIndex)
        }

        if cmdName == "mathcal" || cmdName == "mathscr" {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            let cal = toCalligraphic(arg.content)
            return (cal, arg.nextIndex)
        }

        // Fractions: \frac{num}{den}
        if cmdName == "frac" || cmdName == "dfrac" || cmdName == "tfrac" || cmdName == "cfrac" {
            let numArg = extractArgument(from: input, startingAt: currentIndex)
            let denArg = extractArgument(from: input, startingAt: numArg.nextIndex)
            let num = parseExpression(numArg.content)
            let den = parseExpression(denArg.content)

            let formatted = formatFraction(numerator: num, denominator: den)
            return (formatted, denArg.nextIndex)
        }

        // Radicals: \sqrt[n]{x} or \sqrt{x}
        if cmdName == "sqrt" {
            var rootIndex: String?
            var parseIdx = currentIndex
            while parseIdx < input.endIndex, input[parseIdx] == " " {
                parseIdx = input.index(after: parseIdx)
            }
            if parseIdx < input.endIndex, input[parseIdx] == "[" {
                let bracketArg = extractBracketArgument(from: input, startingAt: parseIdx)
                rootIndex = parseExpression(bracketArg.content)
                parseIdx = bracketArg.nextIndex
            }
            let radicandArg = extractArgument(from: input, startingAt: parseIdx)
            let radicand = parseExpression(radicandArg.content)

            let formatted: String
            if let rootIndex {
                if rootIndex == "3" {
                    formatted = "∛" + wrapIfNeeded(radicand)
                } else if rootIndex == "4" {
                    formatted = "∜" + wrapIfNeeded(radicand)
                } else {
                    let supRoot = canConvertToSuperscript(rootIndex) ? toSuperscript(rootIndex) : rootIndex
                    formatted = "\(supRoot)√" + wrapIfNeeded(radicand)
                }
            } else {
                formatted = "√" + wrapIfNeeded(radicand)
            }
            return (formatted, radicandArg.nextIndex)
        }

        // Binomial: \binom{n}{k}
        if cmdName == "binom" {
            let nArg = extractArgument(from: input, startingAt: currentIndex)
            let kArg = extractArgument(from: input, startingAt: nArg.nextIndex)
            let n = parseExpression(nArg.content)
            let k = parseExpression(kArg.content)
            return ("(\(n) choose \(k))", kArg.nextIndex)
        }

        // Accents: \hat, \bar, \vec, \tilde, \dot, \ddot
        if let accent = accentSymbols[cmdName] {
            let arg = extractArgument(from: input, startingAt: currentIndex)
            let inner = parseExpression(arg.content)
            let formatted = applyCombiningAccent(inner, accent: accent)
            return (formatted, arg.nextIndex)
        }

        // Delimiters: \left, \right
        if cmdName == "left" || cmdName == "right" {
            var delimIdx = currentIndex
            while delimIdx < input.endIndex, input[delimIdx] == " " {
                delimIdx = input.index(after: delimIdx)
            }
            guard delimIdx < input.endIndex else {
                return ("", delimIdx)
            }
            let delimChar = input[delimIdx]
            if delimChar == "\\" {
                let delimCmd = parseCommand(input, startingAt: delimIdx)
                if delimCmd.formatted == "{" || delimCmd.formatted == "}" || delimCmd.formatted == "|" {
                    return (delimCmd.formatted, delimCmd.nextIndex)
                }
                return (delimCmd.formatted, delimCmd.nextIndex)
            }
            if delimChar == "." {
                return ("", input.index(after: delimIdx))
            }
            return (String(delimChar), input.index(after: delimIdx))
        }

        // Environments: \begin{...} ... \end{...}
        if cmdName == "begin" {
            let envArg = extractArgument(from: input, startingAt: currentIndex)
            let envName = envArg.content.trimmingCharacters(in: .whitespaces)
            let endPattern = "\\end{\(envName)}"

            if let endRange = input[envArg.nextIndex...].range(of: endPattern) {
                let body = String(input[envArg.nextIndex ..< endRange.lowerBound])
                let formatted = formatEnvironment(name: envName, body: body)
                return (formatted, endRange.upperBound)
            }
        }

        // Spacing commands
        if cmdName == "quad" {
            return ("  ", currentIndex)
        }
        if cmdName == "qquad" {
            return ("    ", currentIndex)
        }

        // Math functions (sin, cos, log, softmax, etc.)
        if mathFunctions.contains(cmdName) {
            var parseIdx = currentIndex
            while parseIdx < input.endIndex, input[parseIdx] == " " {
                parseIdx = input.index(after: parseIdx)
            }
            if parseIdx < input.endIndex, input[parseIdx] == "(" || input[parseIdx] == "[" {
                return (cmdName, parseIdx)
            }
            return (cmdName + " ", parseIdx)
        }

        // Lookup symbol in dictionary
        let fullCmd = "\\" + cmdName
        if let symbol = latexSymbols[fullCmd] {
            var formatted = symbol
            if isBinaryOrRelation(symbol) {
                formatted = " \(symbol) "
            }
            return (formatted, currentIndex)
        }

        // Fallback: output command name
        return (cmdName, currentIndex)
    }

    // MARK: - Helpers

    private static func extractArgument(from string: String, startingAt index: String.Index) -> (content: String, nextIndex: String.Index) {
        var idx = index
        while idx < string.endIndex, string[idx] == " " {
            idx = string.index(after: idx)
        }
        guard idx < string.endIndex else {
            return ("", string.endIndex)
        }

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
                        let content = String(string[start ..< current])
                        return (content, string.index(after: current))
                    }
                }
                current = string.index(after: current)
            }
            return (String(string[start...]), string.endIndex)
        }

        // Single character argument or backslash command
        if string[idx] == "\\" {
            var end = string.index(after: idx)
            while end < string.endIndex, string[end].isLetter {
                end = string.index(after: end)
            }
            return (String(string[idx ..< end]), end)
        }

        let nextIdx = string.index(after: idx)
        return (String(string[idx]), nextIdx)
    }

    private static func extractBracketArgument(from string: String, startingAt index: String.Index) -> (content: String, nextIndex: String.Index) {
        guard index < string.endIndex, string[index] == "[" else {
            return ("", index)
        }
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

        let numNeedsParens = num.contains(" ") || num.contains("+") || num.contains("-") || num.contains("=") || num.contains("/")
        let denNeedsParens = den.contains(" ") || den.contains("+") || den.contains("-") || den.contains("=") || den.contains("/")

        let formattedNum = numNeedsParens ? "(\(num))" : num
        let formattedDen = denNeedsParens ? "(\(den))" : den

        return "\(formattedNum) / \(formattedDen)"
    }

    private static func wrapIfNeeded(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 2 && !trimmed.contains(" ") {
            return trimmed
        }
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
            return trimmed
        }
        return "(\(trimmed))"
    }

    private static func formatEnvironment(name: String, body: String) -> String {
        let rows = body.components(separatedBy: "\\\\").map { row in
            row.components(separatedBy: "&").map { cell in
                parseExpression(cell.trimmingCharacters(in: .whitespaces))
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

        // aligned / align / gather
        return rows.map { row in row.joined(separator: " ") }.joined(separator: "\n")
    }

    private static func formatMatrix(rows: [[String]], openBracket: String, closeBracket: String) -> String {
        guard !rows.isEmpty else { return "" }
        if rows.count == 1 {
            let rowStr = rows[0].joined(separator: "  ")
            return "\(openBracket) \(rowStr) \(closeBracket)"
        }
        var lines: [String] = []
        for (i, row) in rows.enumerated() {
            let rowStr = row.joined(separator: "  ")
            let open = i == 0 ? (openBracket.isEmpty ? " " : "⎡") : (i == rows.count - 1 ? (openBracket.isEmpty ? " " : "⎣") : (openBracket.isEmpty ? " " : "⎢"))
            let close = i == 0 ? (closeBracket.isEmpty ? " " : "⎤") : (i == rows.count - 1 ? (closeBracket.isEmpty ? " " : "⎦") : (closeBracket.isEmpty ? " " : "⎥"))
            lines.append("\(open) \(rowStr) \(close)")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatCases(rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        var lines: [String] = []
        for (i, row) in rows.enumerated() {
            let brace = i == 0 ? "⎧" : (i == rows.count - 1 ? "⎩" : "⎪")
            let content = row.joined(separator: "   ")
            lines.append("\(brace) \(content)")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatUnDelimitedMath(_ text: String) -> String {
        guard text.contains("\\") || text.contains("_") || text.contains("^") else {
            return text
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var resultLines: [String] = []

        for lineSub in lines {
            let line = String(lineSub)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // If line contains clear LaTeX commands or math patterns
            if trimmed.contains("\\text{") || trimmed.contains("\\frac{") || trimmed.contains("\\sqrt") ||
                trimmed.contains("\\left(") || trimmed.contains("\\right)") || trimmed.contains("\\sum") ||
                trimmed.contains("\\alpha") || trimmed.contains("\\beta") || trimmed.contains("\\partial")
            {
                resultLines.append(parseExpression(line))
            } else if trimmed.contains("_") || trimmed.contains("^") {
                resultLines.append(formatInlineSubscriptsAndSuperscripts(line))
            } else {
                resultLines.append(line)
            }
        }

        return resultLines.joined(separator: "\n")
    }

    private static func formatInlineSubscriptsAndSuperscripts(_ line: String) -> String {
        var result = line
        // Replace single-letter subscript patterns like d_k -> dₖ, x_i -> xᵢ, x_0 -> x₀
        if let subRegex = try? NSRegularExpression(pattern: #"([a-zA-Z])_([a-zA-Z0-9])\b"#) {
            result = replaceMatches(in: result, regex: subRegex, groupIndex: 0) { match in
                let base = match.prefix(1)
                let sub = match.suffix(1)
                let subChar = toSubscript(String(sub))
                return "\(base)\(subChar)"
            }
        }
        // Replace superscripts like x^2 -> x², QK^T -> QKᵀ
        if let supRegex = try? NSRegularExpression(pattern: #"([a-zA-Z0-9])\^([a-zA-Z0-9])\b"#) {
            result = replaceMatches(in: result, regex: supRegex, groupIndex: 0) { match in
                let parts = match.split(separator: "^")
                if parts.count == 2 {
                    let base = String(parts[0])
                    let sup = toSuperscript(String(parts[1]))
                    return "\(base)\(sup)"
                }
                return match
            }
        }
        return result
    }

    private static func replaceMatches(
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
            let innerText = String(text[targetRange])
            let replaced = transform(innerText)
            result += text[lastIndex ..< fullRange.lowerBound]
            result += replaced
            lastIndex = fullRange.upperBound
        }
        result += text[lastIndex...]
        return result
    }

    private static func cleanSpaces(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.replacingOccurrences(of: " ( ", with: " (")
        result = result.replacingOccurrences(of: " ) ", with: ") ")
        result = result.replacingOccurrences(of: "( ", with: "(")
        result = result.replacingOccurrences(of: " )", with: ")")
        result = result.replacingOccurrences(of: " ,", with: ",")
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isBinaryOrRelation(_ symbol: String) -> Bool {
        let binaryOps = ["±", "∓", "×", "÷", "·", "⊕", "⊗", "⊙", "≤", "≥", "≠", "≈", "≡", "∼", "∝", "∈", "∉", "⊂", "⊃", "⊆", "⊇", "∩", "∪", "∧", "∨", "→", "←", "↔", "⇒", "⇐", "⇔", "↦"]
        return binaryOps.contains(symbol)
    }

    // MARK: - Character Mappings

    public static func canConvertToSuperscript(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.allSatisfy { superscriptMap[$0] != nil }
    }

    public static func canConvertToSubscript(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.allSatisfy { subscriptMap[$0] != nil }
    }

    public static func toSuperscript(_ text: String) -> String {
        var result = ""
        for char in text {
            if let sup = superscriptMap[char] {
                result.append(sup)
            } else {
                result.append(char)
            }
        }
        return result
    }

    public static func toSubscript(_ text: String) -> String {
        var result = ""
        for char in text {
            if let sub = subscriptMap[char] {
                result.append(sub)
            } else {
                result.append(char)
            }
        }
        return result
    }

    private static func toBlackboardBold(_ text: String) -> String {
        var result = ""
        for char in text {
            if let bb = blackboardBoldMap[char] {
                result.append(bb)
            } else {
                result.append(char)
            }
        }
        return result
    }

    private static func toCalligraphic(_ text: String) -> String {
        var result = ""
        for char in text {
            if let cal = calligraphicMap[char] {
                result.append(cal)
            } else {
                result.append(char)
            }
        }
        return result
    }

    private static func applyCombiningAccent(_ text: String, accent: String) -> String {
        guard !text.isEmpty else { return "" }
        if text.count == 1 {
            return text + accent
        }
        return text + accent
    }

    // MARK: - Dictionaries

    private static let superscriptMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "*": "﹡",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ",
        "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ",
        "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ",
        "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
        "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ",
        "J": "ᴶ", "K": "ᴷ", "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ",
        "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ",
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ",
        "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
        "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    private static let blackboardBoldMap: [Character: Character] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
        "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
        "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
        "V": "𝕏", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ", "1": "𝟙",
    ]

    private static let calligraphicMap: [Character: Character] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ", "G": "𝒢",
        "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ", "M": "ℳ", "N": "𝒩",
        "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ", "S": "𝒮", "T": "𝒯", "U": "𝒰",
        "V": "𝒱", "W": "𝒲", "X": "𝒳", "Y": "𝒴", "Z": "𝒵",
    ]

    private static let accentSymbols: [String: String] = [
        "hat": "\u{0302}",
        "bar": "\u{0304}",
        "vec": "\u{20D7}",
        "tilde": "\u{0303}",
        "dot": "\u{0307}",
        "ddot": "\u{0308}",
        "check": "\u{030C}",
        "breve": "\u{0306}",
        "acute": "\u{0301}",
        "grave": "\u{0300}",
    ]

    private static let mathFunctions: Set<String> = [
        "sin", "cos", "tan", "sec", "csc", "cot",
        "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh",
        "log", "ln", "lg", "exp",
        "lim", "max", "min", "sup", "inf",
        "argmax", "argmin", "det", "dim", "ker",
        "deg", "gcd", "Pr", "arg", "hom", "rank",
        "softmax", "sigmoid", "diag", "trace", "tr",
        "ReLU", "GELU", "Var", "Cov", "Corr",
    ]

    private static let latexSymbols: [String: String] = [
        // Greek lowercase
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
        "\\epsilon": "ε", "\\varepsilon": "ε", "\\zeta": "ζ", "\\eta": "η",
        "\\theta": "θ", "\\vartheta": "ϑ", "\\iota": "ι", "\\kappa": "κ",
        "\\varkappa": "ϰ", "\\lambda": "λ", "\\mu": "μ", "\\nu": "ν",
        "\\xi": "ξ", "\\pi": "π", "\\varpi": "ϖ", "\\rho": "ρ",
        "\\varrho": "ϱ", "\\sigma": "σ", "\\varsigma": "ς", "\\tau": "τ",
        "\\upsilon": "υ", "\\phi": "φ", "\\varphi": "ϕ", "\\chi": "χ",
        "\\psi": "ψ", "\\omega": "ω",

        // Greek uppercase
        "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ",
        "\\Xi": "Ξ", "\\Pi": "Π", "\\Sigma": "Σ", "\\Upsilon": "Υ",
        "\\Phi": "Φ", "\\Psi": "Ψ", "\\Omega": "Ω",

        // Relations
        "\\leq": "≤", "\\le": "≤", "\\geq": "≥", "\\ge": "≥",
        "\\neq": "≠", "\\ne": "≠", "\\approx": "≈", "\\equiv": "≡",
        "\\sim": "∼", "\\simeq": "≃", "\\cong": "≅", "\\propto": "∝",
        "\\parallel": "∥", "\\perp": "⊥", "\\ll": "≪", "\\gg": "≫",
        "\\prec": "≺", "\\succ": "≻", "\\preceq": "⪯", "\\succeq": "⪰",

        // Arithmetic & binary operators
        "\\pm": "±", "\\mp": "∓", "\\times": "×", "\\div": "÷",
        "\\cdot": "·", "\\ast": "∗", "\\star": "⋆", "\\circ": "∘",
        "\\bullet": "•", "\\oplus": "⊕", "\\ominus": "⊖", "\\otimes": "⊗",
        "\\oslash": "⊘", "\\odot": "⊙",

        // Set & logic
        "\\in": "∈", "\\notin": "∉", "\\ni": "∋", "\\owns": "∋",
        "\\subset": "⊂", "\\supset": "⊃", "\\subseteq": "⊆", "\\supseteq": "⊇",
        "\\subsetneq": "⊊", "\\supsetneq": "⊋", "\\cap": "∩", "\\cup": "∪",
        "\\setminus": "∖", "\\emptyset": "∅", "\\varnothing": "∅",
        "\\forall": "∀", "\\exists": "∃", "\\nexists": "∄",
        "\\land": "∧", "\\wedge": "∧", "\\lor": "∨", "\\vee": "∨",
        "\\neg": "¬", "\\lnot": "¬", "\\top": "⊤", "\\bot": "⊥",

        // Arrows
        "\\to": "→", "\\rightarrow": "→", "\\leftarrow": "←",
        "\\leftrightarrow": "↔", "\\Rightarrow": "⇒", "\\implies": "⇒",
        "\\Leftarrow": "⇐", "\\Leftrightarrow": "⇔", "\\iff": "⇔",
        "\\mapsto": "↦", "\\uparrow": "↑", "\\downarrow": "↓",
        "\\nearrow": "↗", "\\searrow": "↘",

        // Calculus & symbols
        "\\sum": "∑", "\\prod": "∏", "\\coprod": "∐",
        "\\int": "∫", "\\iint": "∬", "\\iiint": "∭", "\\oint": "∮",
        "\\bigcup": "⋃", "\\bigcap": "⋂", "\\bigoplus": "⨁", "\\bigotimes": "⨂",
        "\\infty": "∞", "\\partial": "∂", "\\nabla": "∇",
        "\\dots": "…", "\\cdots": "…", "\\ldots": "…", "\\vdots": "⋮", "\\ddots": "⋱",
        "\\hbar": "ℏ", "\\ell": "ℓ", "\\Re": "ℜ", "\\Im": "ℑ", "\\aleph": "ℵ",
        "\\prime": "′", "\\dagger": "†", "\\ddagger": "‡", "\\degree": "°",
        "\\angle": "∠",

        // Delimiters
        "\\langle": "⟨", "\\rangle": "⟩", "\\|": "‖",
        "\\lfloor": "⌊", "\\rfloor": "⌋", "\\lceil": "⌈", "\\rceil": "⌉",
    ]
}
