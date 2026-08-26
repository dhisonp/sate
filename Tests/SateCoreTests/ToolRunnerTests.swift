import Foundation
@testable import SateCore
import Testing

private struct StubProvider: SearchProvider, Sendable {
    var searchHandler: @Sendable (String, Int) async throws -> [SearchResult]

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        try await searchHandler(query, limit)
    }
}

@Suite("ToolRunner")
struct ToolRunnerTests {
    @Test("Single call executes and returns search results")
    func singleCall() async {
        let stub = StubProvider { query, _ in
            [SearchResult(title: "Result for \(query)", url: "https://example.com/\(query)", snippet: "Snippet")]
        }
        let runner = ToolRunner(searchProvider: stub)
        let calls = [ToolCall(id: "call_1", name: "web_search", arguments: #"{"query":"Swift 6"}"#)]

        let results = await runner.execute(toolCalls: calls, round: 1)
        #expect(results.count == 1)
        #expect(results[0].toolCallID == "call_1")
        #expect(results[0].results.count == 1)
        #expect(results[0].content.contains("Result for Swift 6"))
        #expect(results[0].error == nil)
    }

    @Test("Parallel calls in one round execute and maintain deterministic order")
    func parallelCalls() async {
        let stub = StubProvider { query, _ in
            if query == "first" {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            return [SearchResult(title: "Result \(query)", url: "https://example.com/\(query)", snippet: "s")]
        }
        let runner = ToolRunner(searchProvider: stub)
        let calls = [
            ToolCall(id: "call_0", name: "web_search", arguments: #"{"query":"first"}"#),
            ToolCall(id: "call_1", name: "web_search", arguments: #"{"query":"second"}"#),
            ToolCall(id: "call_2", name: "web_search", arguments: #"{"query":"third"}"#),
        ]

        let results = await runner.execute(toolCalls: calls, round: 1)
        #expect(results.count == 3)
        #expect(results[0].toolCallID == "call_0")
        #expect(results[1].toolCallID == "call_1")
        #expect(results[2].toolCallID == "call_2")
    }

    @Test("Exceeding max rounds returns budget spent without error")
    func maxRoundsCap() async {
        let stub = StubProvider { _, _ in [] }
        let runner = ToolRunner(searchProvider: stub, maxRounds: 3)
        let calls = [ToolCall(id: "call_1", name: "web_search", arguments: #"{"query":"test"}"#)]

        let results = await runner.execute(toolCalls: calls, round: 4)
        #expect(results.count == 1)
        #expect(results[0].budgetSpent == true)
        #expect(results[0].content.contains("budget spent"))
    }

    @Test("Calls per round are capped at 4, excess are skipped with budget message")
    func maxCallsPerRoundCap() async {
        let stub = StubProvider { query, _ in
            [SearchResult(title: query, url: "https://example.com", snippet: "")]
        }
        let runner = ToolRunner(searchProvider: stub)
        let calls = (0 ..< 6).map { index in
            ToolCall(id: "call_\(index)", name: "web_search", arguments: #"{"query":"q\#(index)"}"#)
        }

        let results = await runner.execute(toolCalls: calls, round: 1)
        #expect(results.count == 6)
        #expect(results[0].budgetSpent == false)
        #expect(results[3].budgetSpent == false)
        #expect(results[4].budgetSpent == true)
        #expect(results[5].budgetSpent == true)
        #expect(results[4].content.contains("maximum 4 calls per round"))
    }

    @Test("Malformed tool arguments yield repair message rather than fatal error")
    func malformedArguments() async {
        let runner = ToolRunner(searchProvider: nil)
        let calls = [ToolCall(id: "call_bad", name: "web_search", arguments: "{not-valid-json")]

        let results = await runner.execute(toolCalls: calls, round: 1)
        #expect(results.count == 1)
        #expect(results[0].error != nil)
        #expect(results[0].content.contains("Malformed arguments JSON"))
    }

    @Test("Provider error mid-round returns search unavailable message")
    func providerError() async {
        let stub = StubProvider { _, _ in
            throw SearchError.rateLimited("Rate limit 429")
        }
        let runner = ToolRunner(searchProvider: stub)
        let calls = [ToolCall(id: "call_1", name: "web_search", arguments: #"{"query":"test"}"#)]

        let results = await runner.execute(toolCalls: calls, round: 1)
        #expect(results.count == 1)
        #expect(results[0].content.contains("Search unavailable"))
        #expect(results[0].error != nil)
    }

    @Test("Unknown tool returns error result")
    func unknownTool() async {
        let runner = ToolRunner(searchProvider: nil)
        let calls = [ToolCall(id: "call_calc", name: "calculator", arguments: #"{"expr":"2+2"}"#)]

        let results = await runner.execute(toolCalls: calls, round: 1)
        #expect(results.count == 1)
        #expect(results[0].content.contains("Unknown tool"))
    }
}
