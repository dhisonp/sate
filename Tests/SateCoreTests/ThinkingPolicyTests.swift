import Foundation
@testable import SateCore
import Testing

@Suite("ThinkingPolicy")
struct ThinkingPolicyTests {
    @Test("Off level emits provider-appropriate disable payloads for reasoning models")
    func offEmitsDisablePayloads() {
        let qwenModels = ["@cf/qwen/qwen3.8-27b", "qwen/qwen-2.5-max"]
        for model in qwenModels {
            let extra = ThinkingPolicy.extra(for: model, level: .off)
            #expect(
                extra == ["enable_thinking": .bool(false)],
                "Model \(model) must emit enable_thinking: false when .off"
            )
        }

        let googleModels = ["@cf/google/gemma-4-26b-a4b-it", "google/gemini-2.5-flash", "gemini-2.0-flash-thinking-exp"]
        for model in googleModels {
            let extra = ThinkingPolicy.extra(for: model, level: .off)
            #expect(
                extra == [
                    "thinking_config": .object(["thinking_budget": .number(0)]),
                    "enable_thinking": .bool(false),
                ],
                "Model \(model) must emit Google thinking disable payload when .off"
            )
        }

        let anthropicModels = ["anthropic/claude-3-7-sonnet", "claude-3-7-sonnet"]
        for model in anthropicModels {
            let extra = ThinkingPolicy.extra(for: model, level: .off)
            #expect(extra == ["thinking": .object(["type": .string("disabled")])])
        }

        let deepSeekModels = ["deepseek/deepseek-r1", "deepseek-r1"]
        for model in deepSeekModels {
            let extra = ThinkingPolicy.extra(for: model, level: .off)
            #expect(extra == ["thinking": .object(["enabled": .bool(false)])])
        }

        let emptyModels = [
            "openai/gpt-5.2",
            "openai/o3-mini",
            "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
            "unknown/model",
        ]
        for model in emptyModels {
            let extra = ThinkingPolicy.extra(for: model, level: .off)
            #expect(extra.isEmpty, "Model \(model) must produce empty extra when level is .off")
        }
    }

    @Test("OpenAI models emit reasoning_effort with matching level string")
    func openAIEffortLevels() {
        let models = ["openai/o3-mini", "openai/gpt-5.2", "o1-preview", "o4-mini"]
        for model in models {
            #expect(ThinkingPolicy.extra(for: model, level: .low) == ["reasoning_effort": .string("low")])
            #expect(ThinkingPolicy.extra(for: model, level: .medium) == ["reasoning_effort": .string("medium")])
            #expect(ThinkingPolicy.extra(for: model, level: .high) == ["reasoning_effort": .string("high")])
        }
    }

    @Test("Anthropic models emit thinking object with ordered token budgets")
    func anthropicTokenBudgets() {
        let models = ["anthropic/claude-3-7-sonnet", "anthropic/claude-opus-5", "claude-3-7-sonnet"]
        for model in models {
            let low = ThinkingPolicy.extra(for: model, level: .low)
            #expect(low == [
                "thinking": .object([
                    "type": .string("enabled"),
                    "budget_tokens": .number(2000),
                ]),
            ])

            let med = ThinkingPolicy.extra(for: model, level: .medium)
            #expect(med == [
                "thinking": .object([
                    "type": .string("enabled"),
                    "budget_tokens": .number(8000),
                ]),
            ])

            let high = ThinkingPolicy.extra(for: model, level: .high)
            #expect(high == [
                "thinking": .object([
                    "type": .string("enabled"),
                    "budget_tokens": .number(32000),
                ]),
            ])
        }
    }

    @Test("DeepSeek models emit thinking enabled object")
    func deepSeekThinking() {
        let models = ["deepseek/deepseek-r1", "deepseek-ai/deepseek-reasoner", "deepseek-r1"]
        for model in models {
            let extra = ThinkingPolicy.extra(for: model, level: .high)
            #expect(extra == ["thinking": .object(["enabled": .bool(true)])])
        }
    }

    @Test("Qwen models emit enable_thinking")
    func qwenThinking() {
        let models = ["qwen/qwen-2.5-max", "qwen3-72b-instruct", "@cf/qwen/qwen3.8-27b"]
        for model in models {
            let extra = ThinkingPolicy.extra(for: model, level: .high)
            #expect(extra == ["enable_thinking": .bool(true)])
        }
    }

    @Test("Google models emit thinking_config and enable_thinking")
    func googleThinking() {
        let extra = ThinkingPolicy.extra(for: "@cf/google/gemma-4-26b-a4b-it", level: .medium)
        #expect(extra == [
            "thinking_config": .object(["thinking_budget": .number(8192)]),
            "enable_thinking": .bool(true),
        ])
    }

    @Test("Non-reasoning catalog models emit empty extra even at high level")
    func nonReasoningCatalogModelSuppressed() {
        let restModel = "@cf/meta/llama-3.3-70b-instruct-fp8-fast"
        let compatModel = "workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast"

        for level in [ThinkingLevel.low, .medium, .high] {
            #expect(ThinkingPolicy.extra(for: restModel, level: level).isEmpty)
            #expect(ThinkingPolicy.extra(for: compatModel, level: level).isEmpty)
        }
    }

    @Test("Unknown model family emits empty extra")
    func unknownFamilyEmitsEmpty() {
        for level in [ThinkingLevel.low, .medium, .high] {
            #expect(ThinkingPolicy.extra(for: "custom-unsupported-vendor/model-v1", level: level).isEmpty)
        }
    }

    @Test("SateSettings defaults thinkingLevel to .off and decodes additively")
    func settingsThinkingLevelDefaults() throws {
        let defaults = SateSettings()
        #expect(defaults.thinkingLevel == .off)

        // Decoding JSON without thinkingLevel key yields .off
        let jsonWithout = Data("{}".utf8)
        let decodedWithout = try JSONDecoder().decode(SateSettings.self, from: jsonWithout)
        #expect(decodedWithout.thinkingLevel == .off)

        // Decoding JSON with thinkingLevel key
        let jsonWith = Data(#"{"thinkingLevel": "high"}"#.utf8)
        let decodedWith = try JSONDecoder().decode(SateSettings.self, from: jsonWith)
        #expect(decodedWith.thinkingLevel == .high)

        // Round-trip encoding
        var modified = SateSettings()
        modified.thinkingLevel = .medium
        let encoded = try JSONEncoder().encode(modified)
        let decodedRoundTrip = try JSONDecoder().decode(SateSettings.self, from: encoded)
        #expect(decodedRoundTrip.thinkingLevel == .medium)
    }

    @Test("SateSettings defaults showThinking to true and decodes additively")
    func settingsShowThinkingDefaults() throws {
        let defaults = SateSettings()
        #expect(defaults.showThinking == true)

        // Decoding JSON without showThinking key yields true
        let jsonWithout = Data("{}".utf8)
        let decodedWithout = try JSONDecoder().decode(SateSettings.self, from: jsonWithout)
        #expect(decodedWithout.showThinking == true)

        // Decoding JSON with showThinking: false
        let jsonWith = Data(#"{"showThinking": false}"#.utf8)
        let decodedWith = try JSONDecoder().decode(SateSettings.self, from: jsonWith)
        #expect(decodedWith.showThinking == false)

        // Round-trip encoding
        var modified = SateSettings()
        modified.showThinking = false
        let encoded = try JSONEncoder().encode(modified)
        let decodedRoundTrip = try JSONDecoder().decode(SateSettings.self, from: encoded)
        #expect(decodedRoundTrip.showThinking == false)
    }
}
