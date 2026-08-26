import Foundation

/// Estimates prompt size without a tokenizer.
///
/// There is no tokenizer on device (no third-party dependencies, and shipping BPE
/// vocabularies for every provider is not viable), so the estimate starts from a
/// characters-per-token constant and is then *calibrated* from the
/// `usage.prompt_tokens` the gateway reports for a real request. English prose,
/// CJK and dense code differ by 2-3x, and each model string has its own
/// tokenizer, so the ratio is tracked per model rather than globally.
public struct TokenEstimator: Sendable, Codable {
    /// EMA weight given to a new observation. 0.3 converges within a handful of
    /// turns while still absorbing a single atypical message.
    public static let smoothingFactor: Double = 0.3

    /// Plausibility gate for a calibration sample. Below ~1.0 chars/token is
    /// impossible for any real tokenizer; above ~12 means the character count and
    /// the reported token count did not describe the same payload (cached prompt,
    /// mismatched request, provider bug). Either way one bad response must not
    /// poison the model's ratio for the rest of the session.
    public static let minimumPlausibleRatio: Double = 1.0
    public static let maximumPlausibleRatio: Double = 12.0

    /// Role labels, message framing and separators cost a few tokens per message
    /// on every chat schema. Flat 4 is the usual OpenAI-compat figure.
    public static let perMessageOverheadTokens: Int = 4

    public private(set) var defaultCharactersPerToken: Double
    /// Learned chars-per-token, keyed by the free-form model string.
    public private(set) var calibratedRatios: [String: Double]

    public init(defaultCharactersPerToken: Double = 3.6) {
        // A non-positive default would divide by zero on the very first estimate.
        self.defaultCharactersPerToken = defaultCharactersPerToken > 0 ? defaultCharactersPerToken : 3.6
        self.calibratedRatios = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case defaultCharactersPerToken
        case calibratedRatios
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent(Double.self, forKey: .defaultCharactersPerToken) ?? 3.6
        defaultCharactersPerToken = stored > 0 ? stored : 3.6
        calibratedRatios = try container.decodeIfPresent([String: Double].self, forKey: .calibratedRatios) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultCharactersPerToken, forKey: .defaultCharactersPerToken)
        try container.encode(calibratedRatios, forKey: .calibratedRatios)
    }

    /// Folds one observed (characters sent, tokens billed) pair into the model's
    /// ratio. `characters` is the raw character count of everything sent, so the
    /// learned ratio quietly absorbs some of the framing overhead too; that biases
    /// later estimates slightly high, which is the safe direction for a budget.
    public mutating func calibrate(model: String, characters: Int, promptTokens: Int) {
        guard !model.isEmpty, characters > 0, promptTokens > 0 else { return }
        let observed = Double(characters) / Double(promptTokens)
        guard observed >= Self.minimumPlausibleRatio, observed <= Self.maximumPlausibleRatio else { return }
        let current = charactersPerToken(for: model)
        let blended = current * (1 - Self.smoothingFactor) + observed * Self.smoothingFactor
        calibratedRatios[model] = blended
    }

    public func charactersPerToken(for model: String) -> Double {
        guard let ratio = calibratedRatios[model], ratio > 0 else { return defaultCharactersPerToken }
        return ratio
    }

    public func estimate(characters: Int, model: String) -> Int {
        guard characters > 0 else { return 0 }
        return Int((Double(characters) / charactersPerToken(for: model)).rounded(.up))
    }

    /// Total prompt estimate for a message list, including per-message framing and
    /// the system prompt when one is passed separately.
    public func estimate(_ messages: [Message], systemPrompt: String?, model: String) -> Int {
        var total = 0
        if let systemPrompt, !systemPrompt.isEmpty {
            total += estimate(characters: systemPrompt.count, model: model) + Self.perMessageOverheadTokens
        }
        for message in messages {
            // `reasoning` is deliberately excluded: it is never replayed, so
            // counting it would inflate the budget against text we do not send.
            total += estimate(characters: message.text.count, model: model) + Self.perMessageOverheadTokens
        }
        return total
    }
}
