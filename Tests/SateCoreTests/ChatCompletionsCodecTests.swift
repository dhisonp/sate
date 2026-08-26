import Foundation
import Testing

@testable import SateCore

@Suite("ChatCompletionsCodec")
struct ChatCompletionsCodecTests {
    let codec = ChatCompletionsCodec()

    private func encodedBody(
        _ request: ChatCompletionRequest, stream: Bool = true
    ) throws -> [String: Any] {
        let data = try codec.encodeBody(request, stream: stream)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Encoding

    @Test("System prompt leads the message array")
    func systemPromptLeads() throws {
        let request = ChatCompletionRequest(
            model: "openai/gpt-5.2",
            messages: [.user("hello")],
            systemPrompt: "Be terse.")
        let body = try encodedBody(request)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0] == ["role": "system", "content": "Be terse."])
        #expect(messages[1] == ["role": "user", "content": "hello"])
    }

    @Test("Reasoning is never replayed to the model")
    func reasoningIsNotReplayed() throws {
        let assistant = Message(
            role: .assistant, content: [.text("42")], reasoning: "long chain of thought")
        let body = try encodedBody(
            ChatCompletionRequest(model: "m", messages: [.user("q"), assistant]))
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[1] == ["role": "assistant", "content": "42"])
        let raw = String(decoding: try codec.encodeBody(
            ChatCompletionRequest(model: "m", messages: [assistant]), stream: true), as: UTF8.self)
        #expect(!raw.contains("reasoning"))
        #expect(!raw.contains("long chain of thought"))
    }

    @Test("Empty assistant turns are dropped, empty user turns are not")
    func emptyAssistantIsDropped() throws {
        let request = ChatCompletionRequest(
            model: "m",
            messages: [
                .user("hi"),
                Message(role: .assistant, content: [.text("")]),
                .user(""),
            ])
        let messages = try #require(try encodedBody(request)["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "user", "content": "hi"],
            ["role": "user", "content": ""],
        ])
    }

    @Test("max_tokens is always sent, as an integer")
    func maxTokensAlwaysSent() throws {
        let body = try encodedBody(ChatCompletionRequest(model: "m", maxTokens: nil))
        #expect(body["max_tokens"] as? Int == ChatCompletionsCodec.defaultMaxTokens)
        let raw = String(
            decoding: try codec.encodeBody(
                ChatCompletionRequest(model: "m", maxTokens: 100), stream: true), as: UTF8.self)
        #expect(raw.contains("\"max_tokens\":100"))
    }

    @Test("A positive extra max_tokens overrides, a useless one does not")
    func maxTokensOverride() throws {
        // A legitimate per-provider tune wins.
        let tuned = try encodedBody(
            ChatCompletionRequest(model: "m", maxTokens: 256, extra: ["max_tokens": .number(9000)]))
        #expect(tuned["max_tokens"] as? Int == 9000)

        // Anything that would leave the request UNBOUNDED is ignored: `max_tokens`
        // is the only hard ceiling on a runaway generation's bill.
        for useless: JSONValue in [.null, .number(0), .number(-1), .string("lots")] {
            let body = try encodedBody(
                ChatCompletionRequest(model: "m", maxTokens: 256, extra: ["max_tokens": useless]))
            #expect(body["max_tokens"] as? Int == 256, "\(useless) must not remove the bound")
        }
    }

    @Test("stream_options only when streaming and enabled")
    func streamOptionsToggle() throws {
        let on = try encodedBody(ChatCompletionRequest(model: "m", includeUsage: true))
        #expect((on["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect(on["stream"] as? Bool == true)

        let off = try encodedBody(ChatCompletionRequest(model: "m", includeUsage: false))
        #expect(off["stream_options"] == nil)

        let nonStreaming = try encodedBody(
            ChatCompletionRequest(model: "m", includeUsage: true), stream: false)
        #expect(nonStreaming["stream_options"] == nil)
        #expect(nonStreaming["stream"] as? Bool == false)
    }

    @Test("extra merges at top level but cannot clobber model, messages or stream")
    func extraCannotClobberReservedKeys() throws {
        let request = ChatCompletionRequest(
            model: "openai/gpt-5.2",
            messages: [.user("hi")],
            includeUsage: false,
            extra: [
                "model": .string("evil/model"),
                "messages": .array([.string("nonsense")]),
                "stream": .bool(false),
                "top_p": .number(0.5),
                "provider": .object(["order": .array([.string("a")])]),
            ])
        let body = try encodedBody(request)
        #expect(body["model"] as? String == "openai/gpt-5.2")
        #expect(body["stream"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "hi"]])
        #expect(body["top_p"] as? Double == 0.5)
        #expect(((body["provider"] as? [String: Any])?["order"] as? [String]) == ["a"])
    }

    // MARK: - Decoding

    @Test("content delta becomes a textDelta")
    func textDelta() throws {
        let events = try codec.decode(
            dataPayload: #"{"choices":[{"delta":{"content":"Hel"}}]}"#)
        #expect(events == [.textDelta("Hel")])
    }

    @Test("reasoning_content and reasoning both become reasoningDelta")
    func reasoningDelta() throws {
        #expect(
            try codec.decode(dataPayload: #"{"choices":[{"delta":{"reasoning_content":"think"}}]}"#)
                == [.reasoningDelta("think")])
        #expect(
            try codec.decode(dataPayload: #"{"choices":[{"delta":{"reasoning":"think"}}]}"#)
                == [.reasoningDelta("think")])
    }

    @Test("First chunk with id/model yields started")
    func startedEvent() throws {
        let events = try codec.decode(
            dataPayload: #"{"id":"resp_1","model":"openai/gpt-5.2","choices":[{"delta":{"role":"assistant"}}]}"#)
        #expect(events == [.started(responseID: "resp_1", model: "openai/gpt-5.2")])
    }

    @Test("Empty delta and null content emit nothing")
    func emptyDeltaEmitsNothing() throws {
        #expect(try codec.decode(dataPayload: #"{"choices":[{"delta":{}}]}"#).isEmpty)
        #expect(try codec.decode(dataPayload: #"{"choices":[{"delta":{"content":null}}]}"#).isEmpty)
        #expect(try codec.decode(dataPayload: "[DONE]").isEmpty)
        #expect(try codec.decode(dataPayload: "   ").isEmpty)
    }

    @Test("Tool-call fragments join on the element's index, not its array position")
    func toolCallsJoinOnIndex() throws {
        let first = try codec.decode(
            dataPayload: #"""
            {"choices":[{"delta":{"tool_calls":[{"index":2,"id":"call_a","type":"function","function":{"name":"search","arguments":""}}]}}]}
            """#)
        #expect(first == [
            .toolCallDelta(index: 2, id: "call_a", name: "search", argumentsFragment: "")
        ])

        // Second chunk carries only the continuation: no id, no name, index 2 even
        // though it is the sole element of the array.
        let second = try codec.decode(
            dataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":2,"function":{"arguments":"{\"q\":"}}]}}]}"#)
        #expect(second == [
            .toolCallDelta(index: 2, id: nil, name: nil, argumentsFragment: "{\"q\":")
        ])

        // A fragment without an index is call 0.
        let missingIndex = try codec.decode(
            dataPayload: #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"1}"}}]}}]}"#)
        #expect(missingIndex == [
            .toolCallDelta(index: 0, id: nil, name: nil, argumentsFragment: "1}")
        ])
    }

    @Test("finish_reason yields a finished event")
    func finishReason() throws {
        #expect(
            try codec.decode(dataPayload: #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)
                == [.finished(reason: .length, usage: nil)])
        #expect(
            try codec.decode(dataPayload: #"{"choices":[{"delta":{},"finish_reason":"weird"}]}"#)
                == [.finished(reason: .unknown("weird"), usage: nil)])
    }

    @Test("Usage trailer with empty choices is valid and carries usage")
    func usageTrailer() throws {
        let events = try codec.decode(
            dataPayload: #"{"id":"resp_1","choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4,"total_tokens":15}}"#)
        #expect(events == [
            .started(responseID: "resp_1", model: nil),
            .finished(reason: .stop, usage: Usage(promptTokens: 11, completionTokens: 4, totalTokens: 15)),
        ])
    }

    @Test("Out-of-range numbers in a chunk are dropped, never trapped on")
    func oversizedNumbersDoNotCrash() throws {
        // Every one of these would abort the process through the trapping
        // `Int(Double)` conversion, mid-stream, losing the whole answer since the
        // last checkpoint — and all of them are one line of untrusted JSON away.
        let events = try codec.decode(
            dataPayload: #"{"choices":[],"usage":{"prompt_tokens":1e30,"completion_tokens":-1e30}}"#)
        #expect(events == [.finished(reason: .stop, usage: Usage())])

        let toolCall = try codec.decode(
            dataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":1e30,"function":{"arguments":"{}"}}]}}]}"#)
        #expect(toolCall == [.toolCallDelta(index: 0, id: nil, name: nil, argumentsFragment: "{}")])

        // A NaN/huge `code` must degrade to "no code", not to a crash.
        #expect(throws: GatewayError.inStreamError(code: nil, message: "boom")) {
            try codec.decode(dataPayload: #"{"error":{"message":"boom","code":1e30}}"#)
        }
    }

    @Test("A total_tokens that would overflow saturates instead of trapping")
    func usageTotalSaturates() throws {
        let huge = 9.0e18  // just under Int.max; two of them overflow Int.
        let events = try codec.decode(
            dataPayload: #"{"choices":[],"usage":{"prompt_tokens":\#(huge),"completion_tokens":\#(huge)}}"#)
        let usage = try #require(events.compactMap { event -> Usage? in
            if case .finished(_, let usage) = event { return usage }
            return nil
        }.first)
        #expect(usage.totalTokens == Int.max)
    }

    @Test("Top-level error objects and strings throw inStreamError")
    func inStreamErrors() throws {
        #expect(throws: GatewayError.inStreamError(code: "server_error", message: "boom")) {
            try codec.decode(
                dataPayload: #"{"error":{"message":"boom","type":"server_error"}}"#)
        }
        #expect(throws: GatewayError.inStreamError(code: nil, message: "plain boom")) {
            try codec.decode(dataPayload: #"{"error":"plain boom"}"#)
        }
        // `"error": null` is a field some providers always send; it is not an error.
        #expect(try codec.decode(dataPayload: #"{"error":null,"choices":[{"delta":{"content":"x"}}]}"#)
            == [.textDelta("x")])
    }

    @Test("Undecodable JSON is a protocolError")
    func undecodableIsProtocolError() {
        #expect(throws: GatewayError.self) { try codec.decode(dataPayload: "{not json") }
        #expect(throws: GatewayError.self) { try codec.decode(dataPayload: "[1,2,3]") }
    }

    @Test("decodeComplete turns a whole body into started + delta + finished")
    func decodeCompleteBody() throws {
        let body = Data(#"""
        {"id":"cmpl_9","model":"openai/gpt-5.2","choices":[{"index":0,"message":{"role":"assistant","content":"Hello there"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}
        """#.utf8)
        #expect(try codec.decodeComplete(body) == [
            .started(responseID: "cmpl_9", model: "openai/gpt-5.2"),
            .textDelta("Hello there"),
            .finished(reason: .stop, usage: Usage(promptTokens: 5, completionTokens: 2, totalTokens: 7)),
        ])
    }

    @Test("decodeComplete accepts a content parts array and reports errors")
    func decodeCompleteVariants() throws {
        let parts = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}"#.utf8)
        #expect(try codec.decodeComplete(parts) == [
            .textDelta("ab"),
            .finished(reason: .stop, usage: nil),
        ])
        #expect(throws: GatewayError.inStreamError(code: nil, message: "nope")) {
            try codec.decodeComplete(Data(#"{"error":{"message":"nope"}}"#.utf8))
        }
    }
}
