import Foundation

/// Resolves provider-specific wire fields for thinking / reasoning effort.
///
/// Pure function in SateCore: maps `(model, level)` into extra request body fields.
/// Returns `[:]` when level is `.off` or when the model is known not to support reasoning.
public enum ThinkingPolicy {
    public enum ProviderFamily: Sendable, Hashable {
        case openAI
        case anthropic
        case deepSeek
        case qwen
        case workersAI
        case unknown
    }

    /// Resolves extra JSON body parameters for the given model and thinking level.
    public static func extra(for model: String, level: ThinkingLevel) -> [String: JSONValue] {
        let canonical = model.hasPrefix(ModelCatalog.compatProviderPrefix)
            ? String(model.dropFirst(ModelCatalog.compatProviderPrefix.count))
            : model

        if let option = ModelCatalog.option(id: canonical), !option.reasons {
            return [:]
        }

        let family = providerFamily(for: canonical)
        if level == .off {
            return formatOffExtra(for: family)
        }
        return formatExtra(for: family, level: level)
    }

    /// Formats the extra dictionary when thinking is turned off.
    private static func formatOffExtra(for family: ProviderFamily) -> [String: JSONValue] {
        switch family {
        case .qwen, .workersAI:
            return ["enable_thinking": .bool(false)]
        case .anthropic:
            return ["thinking": .object(["type": .string("disabled")])]
        case .deepSeek:
            return ["thinking": .object(["enabled": .bool(false)])]
        case .openAI, .unknown:
            return [:]
        }
    }

    /// Formats the extra dictionary for a recognized provider family.
    private static func formatExtra(for family: ProviderFamily, level: ThinkingLevel) -> [String: JSONValue] {
        switch family {
        case .openAI:
            return ["reasoning_effort": .string(level.rawValue)]
        case .anthropic:
            return [
                "thinking": .object([
                    "type": .string("enabled"),
                    "budget_tokens": .number(Double(anthropicBudget(for: level))),
                ]),
            ]
        case .deepSeek:
            return ["thinking": .object(["enabled": .bool(true)])]
        case .qwen, .workersAI:
            return ["enable_thinking": .bool(true)]
        case .unknown:
            return [:]
        }
    }

    private static func anthropicBudget(for level: ThinkingLevel) -> Int {
        switch level {
        case .off: return 0
        case .low: return 2000
        case .medium: return 8000
        case .high: return 32000
        }
    }

    /// Determines the provider family from the model string.
    public static func providerFamily(for model: String) -> ProviderFamily {
        let lower = model.lowercased()
        if lower.hasPrefix("openai/") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
            return .openAI
        }
        if lower.hasPrefix("anthropic/") || lower.hasPrefix("claude") {
            return .anthropic
        }
        if lower.hasPrefix("deepseek/") || lower.hasPrefix("deepseek-ai/") || lower.contains("deepseek") {
            return .deepSeek
        }
        if lower.contains("qwen") {
            return .qwen
        }
        if lower.hasPrefix("@cf/") || lower.hasPrefix("workers-ai/@cf/") {
            return .workersAI
        }
        return .unknown
    }
}
