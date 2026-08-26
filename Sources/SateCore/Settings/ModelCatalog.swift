import Foundation

/// One entry the model picker can offer. `id` is the canonical wire string in
/// its **REST** form; `GatewayRoute.wireModel(_:for:)` rewrites it if a request
/// ends up on the compat host instead.
public struct ModelOption: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let vendor: String
    public let summary: String
    /// The provider's advertised context window. Used as the default input
    /// budget for a model the user has never tuned.
    public let contextTokens: Int
    public let reasons: Bool
    public let supportsTools: Bool

    public init(
        id: String, name: String, vendor: String, summary: String,
        contextTokens: Int, reasons: Bool, supportsTools: Bool
    ) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.summary = summary
        self.contextTokens = contextTokens
        self.reasons = reasons
        self.supportsTools = supportsTools
    }

    public var displayName: String {
        "\(name) · \(vendor)"
    }
}

/// The models Sate offers by name. Deliberately only Cloudflare's own `@cf`
/// Workers AI catalog: those run on Cloudflare's infrastructure, so they need no
/// BYOK provider key and no Unified Billing fall-through, which makes them the
/// only models that work on a fresh install with nothing but an account id and a
/// token. Every other `provider/model` string the gateway serves is still
/// reachable through the picker's *Custom* row.
///
/// This list is a convenience, not a constraint. It is not fetched at runtime:
/// there is no unauthenticated endpoint that enumerates gateway-reachable models,
/// and a settings screen that can fail to populate is worse than a short static
/// list plus free-form entry.
public enum ModelCatalog {
    /// Workers AI ids carry this prefix on the REST route.
    public static let workersAIPrefix = "@cf/"
    /// The compat host qualifies them with a provider segment instead.
    public static let compatProviderPrefix = "workers-ai/"

    public static let workersAI: [ModelOption] = [
        ModelOption(
            id: "@cf/google/gemma-4-26b-a4b-it",
            name: "Gemma 4 26B",
            vendor: "Google",
            summary: "Mixture-of-experts, 4B active. Long context and a thinking mode.",
            contextTokens: 256_000,
            reasons: true,
            supportsTools: true
        ),
        ModelOption(
            id: "@cf/qwen/qwen3.8-27b",
            name: "Qwen 3.8 27B",
            vendor: "Alibaba",
            summary: "General-purpose and agentic, with reasoning. Longest window here.",
            contextTokens: 262_144,
            reasons: true,
            supportsTools: true
        ),
        ModelOption(
            id: "@cf/qwen/qwen3-30b-a3b-fp8",
            name: "Qwen3 30B A3B",
            vendor: "Alibaba",
            summary: "3B active per pass — fast, at a much smaller window.",
            contextTokens: 32768,
            reasons: true,
            supportsTools: true
        ),
        ModelOption(
            id: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
            name: "Llama 3.3 70B Fast",
            vendor: "Meta",
            summary: "fp8-quantized for latency. Cheapest of these per token.",
            contextTokens: 24000,
            reasons: false,
            supportsTools: true
        ),
    ]

    public static var all: [ModelOption] {
        workersAI
    }

    /// Chosen for the default chat model because it pairs the long window with a
    /// small active-parameter count, so a long transcript stays affordable.
    public static let defaultChat = workersAI[0]

    /// Titling is one short call per conversation and never user-facing prose, so
    /// it takes the fastest and cheapest entry rather than the best one.
    public static let defaultTitle = workersAI[3]

    public static func option(id: String) -> ModelOption? {
        all.first { $0.id == id }
    }

    public static func contains(_ id: String) -> Bool {
        option(id: id) != nil
    }

    /// True for either spelling, so a value saved while the compat route was in
    /// use is still recognised as a Workers AI model.
    public static func isWorkersAI(_ model: String) -> Bool {
        model.hasPrefix(workersAIPrefix) || model.hasPrefix(compatProviderPrefix + workersAIPrefix)
    }

    /// The catalog's default window for a known model. `nil` for a custom string:
    /// the gateway resolves those and we have no way to know their window.
    public static func window(for model: String) -> ContextWindow? {
        guard let option = option(id: model) else { return nil }
        return ContextWindow(
            model: model,
            inputBudgetTokens: option.contextTokens,
            reserveForOutputTokens: min(8000, max(1024, option.contextTokens / 4))
        )
    }
}
