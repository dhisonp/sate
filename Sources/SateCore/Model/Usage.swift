import Foundation

/// Token accounting reported by the gateway. Arrives in the final `stream_options`
/// chunk, which carries an *empty* `choices` array — see `ChatCompletionsCodec`.
public struct Usage: Codable, Hashable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    public init(promptTokens: Int = 0, completionTokens: Int = 0, totalTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            ?? Usage.clampedSum(promptTokens, completionTokens)
    }

    /// Saturating addition. Both operands come from a provider we do not control,
    /// and a trapping `+` would abort the whole process over a cosmetic total.
    static func clampedSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
        guard overflowed else { return sum }
        return lhs > 0 ? Int.max : Int.min
    }
}
