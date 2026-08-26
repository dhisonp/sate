import Foundation
@testable import SateCore
import Testing

@Suite("ModelCatalog")
struct ModelCatalogTests {
    @Test("Catalog ids are unique, non-empty, and all Workers AI")
    func catalogShape() {
        #expect(!ModelCatalog.all.isEmpty)
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
        for option in ModelCatalog.all {
            #expect(option.id.hasPrefix("@cf/"))
            #expect(ModelCatalog.isWorkersAI(option.id))
            #expect(option.contextTokens > 0)
            #expect(!option.name.isEmpty)
        }
    }

    @Test("Defaults are in the catalog")
    func defaultsAreListed() {
        #expect(ModelCatalog.contains(ModelCatalog.defaultChat.id))
        #expect(ModelCatalog.contains(ModelCatalog.defaultTitle.id))
    }

    @Test("isWorkersAI accepts both spellings and rejects other providers")
    func workersAIDetection() {
        #expect(ModelCatalog.isWorkersAI("@cf/qwen/qwen3.8-27b"))
        #expect(ModelCatalog.isWorkersAI("workers-ai/@cf/qwen/qwen3.8-27b"))
        #expect(!ModelCatalog.isWorkersAI("anthropic/claude-opus-5"))
        #expect(!ModelCatalog.isWorkersAI("dynamic/assistant"))
    }

    @Test("A catalog model gets its real window; a custom string gets the generic default")
    func windows() {
        let settings = SateSettings()
        let known = settings.window(for: "@cf/qwen/qwen3-30b-a3b-fp8")
        #expect(known.inputBudgetTokens == 32768)
        #expect(known.effectiveBudgetTokens < known.inputBudgetTokens)

        let custom = settings.window(for: "some/unlisted-model")
        #expect(custom.inputBudgetTokens == 100_000)
        #expect(custom.model == "some/unlisted-model")
    }

    @Test("A user-tuned window still wins over the catalog")
    func storedWindowWins() {
        var settings = SateSettings()
        settings.contextWindows["@cf/qwen/qwen3-30b-a3b-fp8"] =
            ContextWindow(model: "", inputBudgetTokens: 4096, reserveForOutputTokens: 512)
        #expect(settings.window(for: "@cf/qwen/qwen3-30b-a3b-fp8").inputBudgetTokens == 4096)
    }

    @Test("REST keeps the bare @cf id; compat qualifies it with the provider")
    func wireModelRewriting() {
        let rest = GatewayRoute.rest(accountID: "acct", gatewayID: nil)
        let compat = GatewayRoute.compat(accountID: "acct", gatewayID: "gw")

        #expect(rest.wireModel("@cf/google/gemma-4-26b-a4b-it") == "@cf/google/gemma-4-26b-a4b-it")
        #expect(rest.wireModel("workers-ai/@cf/google/gemma-4-26b-a4b-it")
            == "@cf/google/gemma-4-26b-a4b-it")
        #expect(compat.wireModel("@cf/google/gemma-4-26b-a4b-it")
            == "workers-ai/@cf/google/gemma-4-26b-a4b-it")
        #expect(compat.wireModel("workers-ai/@cf/google/gemma-4-26b-a4b-it")
            == "workers-ai/@cf/google/gemma-4-26b-a4b-it")
    }

    @Test("Non-Workers-AI model strings are never rewritten")
    func wireModelLeavesOthersAlone() {
        let rest = GatewayRoute.rest(accountID: "acct", gatewayID: nil)
        let compat = GatewayRoute.compat(accountID: "acct", gatewayID: "gw")
        for model in ["anthropic/claude-opus-5", "openai/gpt-5.2", "dynamic/assistant"] {
            #expect(rest.wireModel(model) == model)
            #expect(compat.wireModel(model) == model)
        }
    }
}
