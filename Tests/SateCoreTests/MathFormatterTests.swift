import Foundation
@testable import SateCore
import Testing

@Suite("MathFormatter")
struct MathFormatterTests {
    @Test("Formats attention formula from screenshot")
    func attentionFormula() {
        let latex = #"\text{Attention}(Q, K, V) = \text{softmax}\left(\frac{QK^T}{\sqrt{d_k}}\right)V"#
        let formatted = MathFormatter.formatEquation(latex)
        #expect(formatted.contains("Attention(Q, K, V)"))
        #expect(formatted.contains("softmax"))
        #expect(formatted.contains("QKᵀ"))
        #expect(formatted.contains("√dₖ") || formatted.contains("√(dₖ)"))
    }

    @Test("Formats display math delimited with double dollar")
    func displayMathDoubleDollar() {
        let input = "The formula is: $$\\frac{a + b}{c} = d$$ which holds."
        let formatted = MathFormatter.formatText(input)
        #expect(formatted.contains("(a + b) / c = d"))
        #expect(!formatted.contains("$$"))
        #expect(!formatted.contains("\\frac"))
    }

    @Test("Formats bracket display math")
    func displayMathBracket() {
        let input = "Formula:\n\\[\n\\mathcal{L} = -\\sum_{i=1}^N y_i \\log(\\hat{y}_i)\n\\]"
        let formatted = MathFormatter.formatText(input)
        #expect(formatted.contains("ℒ = -∑ᵢ₌₁ᴺ yᵢ log(ŷᵢ)") || formatted.contains("ℒ = - ∑ᵢ₌₁ᴺ yᵢ log(ŷᵢ)") || formatted.contains("ℒ"))
        #expect(!formatted.contains("\\["))
        #expect(!formatted.contains("\\]"))
    }

    @Test("Formats inline math with dollar and parens")
    func inlineMath() {
        let input1 = "Let $x^2 + y^2 = z^2$ be Pythagorean."
        let formatted1 = MathFormatter.formatText(input1)
        #expect(formatted1.contains("x² + y² = z²"))

        let input2 = "Given \\(d_k\\) as dimension."
        let formatted2 = MathFormatter.formatText(input2)
        #expect(formatted2.contains("dₖ"))
    }

    @Test("Does not format currency as math")
    func currencyPreserved() {
        let input = "The price is $50 and $100."
        let formatted = MathFormatter.formatText(input)
        #expect(formatted == "The price is $50 and $100.")
    }

    @Test("Formats quadratic formula with radicals and plus-minus")
    func quadraticFormula() {
        let latex = #"\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#
        let formatted = MathFormatter.formatEquation(latex)
        #expect(formatted.contains("±"))
        #expect(formatted.contains("b² - 4ac"))
        #expect(formatted.contains("2a"))
    }

    @Test("Formats Greek letters and blackboard bold")
    func greekAndBlackboard() {
        let latex = #"\forall \alpha \in \mathbb{R}, \beta \ge 0 \implies \alpha + \beta \in \mathbb{R}"#
        let formatted = MathFormatter.formatEquation(latex)
        #expect(formatted.contains("∀"))
        #expect(formatted.contains("α"))
        #expect(formatted.contains("∈"))
        #expect(formatted.contains("ℝ"))
        #expect(formatted.contains("β"))
        #expect(formatted.contains("≥"))
        #expect(formatted.contains("⇒"))
    }

    @Test("Formats matrices and cases")
    func matricesAndCases() {
        let matrix = #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#
        let formattedMatrix = MathFormatter.formatEquation(matrix)
        #expect(formattedMatrix.contains("a") && formattedMatrix.contains("b") && formattedMatrix.contains("c") && formattedMatrix.contains("d"))

        let cases = #"\begin{cases} 1 & \text{if } x \ge 0 \\ 0 & \text{otherwise} \end{cases}"#
        let formattedCases = MathFormatter.formatEquation(cases)
        #expect(formattedCases.contains("⎧") || formattedCases.contains("⎩"))
        #expect(formattedCases.contains("if x ≥ 0"))
    }

    @Test("Detects standalone equation lines")
    func detectsStandaloneEquations() {
        let screenshotLines = """
        \\text{Attention}(Q, K, V) = \\text{softmax}
        \\left(\\frac{QK^T}{\\sqrt{d_k}}\\right)V
        """
        #expect(MathFormatter.isStandaloneEquation(screenshotLines))

        let prose = "The mathematical operation is calculated as follows for all keys."
        #expect(!MathFormatter.isStandaloneEquation(prose))
    }

    @Test("Formats un-delimited math lines in text")
    func unDelimitedMathText() {
        let input = """
        The mathematical operation is calculated as:
        \\text{Attention}(Q, K, V) = \\text{softmax}
        \\left(\\frac{QK^T}{\\sqrt{d_k}}\\right)V
        where d_k is the dimension of the keys.
        """
        let formatted = MathFormatter.formatText(input)
        #expect(formatted.contains("Attention(Q, K, V)"))
        #expect(formatted.contains("softmax"))
        #expect(formatted.contains("QKᵀ"))
        #expect(formatted.contains("where dₖ is"))
    }
}
