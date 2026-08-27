import Foundation

enum MathTables: Sendable {
    static let superscriptMap: [Character: Character] = [
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

    static let subscriptMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ",
        "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
        "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    static let blackboardBoldMap: [Character: Character] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
        "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
        "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
        "V": "𝕏", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ", "1": "𝟙",
    ]

    static let calligraphicMap: [Character: Character] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ", "G": "𝒢",
        "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ", "M": "ℳ", "N": "𝒩",
        "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ", "S": "𝒮", "T": "𝒯", "U": "𝒰",
        "V": "𝒱", "W": "𝒲", "X": "𝒳", "Y": "𝒴", "Z": "𝒵",
    ]

    static let accentSymbols: [String: String] = [
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

    static let mathFunctions: Set<String> = [
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

    static let latexSymbols: [String: String] = [
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
