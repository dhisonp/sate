import Foundation

/// Mock search provider for offline simulator and test runs.
public struct MockSearchProvider: SearchProvider, Sendable {
    public init() {}

    public func search(_: String, limit _: Int = 5) async throws -> [SearchResult] {
        [
            SearchResult(
                title: "Swift 6 Concurrency and Architecture Overview",
                url: "https://developer.apple.com/documentation/swift/concurrency",
                snippet: "Complete guide to Swift 6 strict concurrency, Sendable checking, and async/await task systems in iOS applications.",
                publishedAt: Date(timeIntervalSince1970: 1_756_000_000),
                siteName: "Apple Developer"
            ),
            SearchResult(
                title: "Cloudflare AI Gateway - Fast, Scalable LLM Broker",
                url: "https://developers.cloudflare.com/ai-gateway",
                snippet: "Cloudflare AI Gateway manages API keys, intelligent model routing, spend limits, rate limiting, and unified logging.",
                publishedAt: Date(timeIntervalSince1970: 1_755_000_000),
                siteName: "Cloudflare Docs"
            ),
        ]
    }
}

/// Offline stand-in for `GatewayClient`, selected when the process is launched
/// with `SATE_MOCK=1`.
///
/// It replays a bundled SSE script through the *real* `SSEParser` and
/// `ChatCompletionsCodec`, at realistic per-chunk delays, so the streaming UI,
/// the coalescer, checkpointing, persistence, tool execution loop, and every error
/// path can be exercised in the simulator with no Cloudflare token and no network.
///
/// Prompt triggers (matched case-insensitively anywhere in the last user turn):
///   * `error` — an in-stream `{"error":…}` after a partial answer
///   * `truncate` — a reply that stops at `finish_reason: length`
///   * `unauthorized` — a 401-equivalent failure before any byte arrives
actor MockGatewayClient: LLMStreaming {
    /// Wall-clock gap between chunks. Fast enough to feel like a real stream,
    /// slow enough that coalescing and the trailing flush timer both matter.
    private static let minimumDelayNanoseconds: UInt64 = 15_000_000
    private static let maximumDelayNanoseconds: UInt64 = 25_000_000

    private var trace: NetworkTrace?

    init() {}

    var lastTrace: NetworkTrace? {
        trace
    }

    nonisolated func stream(
        _ request: ChatCompletionRequest, conversationID _: UUID? = nil
    ) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task { await self.replay(request, continuation: continuation) }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func record(_ trace: NetworkTrace) {
        self.trace = trace
    }

    private func replay(
        _ request: ChatCompletionRequest,
        continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
    ) async {
        let prompt = request.messages.last { $0.role == .user }?.text.lowercased() ?? ""
        let isAnsweringTool = request.messages.last?.role == .tool
        let hasTools = request.tools != nil && !(request.tools?.isEmpty ?? true)
        let start = Date()
        var trace = NetworkTrace(
            route: "mock",
            model: request.model,
            statusCode: 200,
            logID: "mock-\(UUID().uuidString.prefix(8))",
            cacheStatus: "MISS"
        )

        if prompt.contains("unauthorized") {
            trace.statusCode = 401
            trace.duration = Date().timeIntervalSince(start)
            record(trace)
            continuation.finish(
                throwing: GatewayError.unauthorized(message: "Mock: the token was rejected.")
            )
            return
        }

        let script: String
        if isAnsweringTool {
            script = Self.searchAnswerScript
        } else if prompt.contains("error") {
            script = Self.errorScript
        } else if prompt.contains("truncate") {
            script = Self.truncatedScript
        } else if hasTools, prompt.contains("search") || prompt.contains("latest") || prompt.contains("who") || prompt.contains("what") {
            script = Self.searchToolCallScript
        } else {
            script = Self.normalScript
        }

        var parser = SSEParser()
        let codec = ChatCompletionsCodec()
        var sawStarted = false
        var reason: FinishReason?
        var usage: Usage?

        feed: for chunk in Self.chunks(of: script) {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64.random(
                        in: Self.minimumDelayNanoseconds ... Self.maximumDelayNanoseconds
                    )
                )
            } catch {
                trace.duration = Date().timeIntervalSince(start)
                record(trace)
                continuation.finish(throwing: GatewayError.cancelled)
                return
            }

            let bytes = Array(chunk.utf8)
            if trace.bytesReceived == 0 {
                trace.timeToFirstByte = Date().timeIntervalSince(start)
            }
            trace.bytesReceived += bytes.count

            do {
                for event in try parser.consume(bytes) {
                    if event.isTerminator {
                        break feed
                    }
                    let (events, termination) = try codec.decodeChunk(dataPayload: event.data)
                    for streamEvent in events {
                        if case .started = streamEvent {
                            guard !sawStarted else { continue }
                            sawStarted = true
                        }
                        continuation.yield(streamEvent)
                    }
                    if reason == nil, let observed = termination.reason {
                        reason = observed
                    }
                    if let reported = termination.usage {
                        usage = reported
                    }
                }
            } catch let error as GatewayError {
                trace.duration = Date().timeIntervalSince(start)
                record(trace)
                continuation.finish(throwing: error)
                return
            } catch {
                trace.duration = Date().timeIntervalSince(start)
                record(trace)
                continuation.finish(throwing: GatewayError.protocolError("\(error)"))
                return
            }
        }

        _ = parser.finish()
        trace.duration = Date().timeIntervalSince(start)
        record(trace)
        continuation.yield(.finished(reason: reason ?? .truncated, usage: usage))
        continuation.finish()
    }

    private static func chunks(of script: String) -> [String] {
        var out: [String] = []
        for block in script.components(separatedBy: "\n\n") where !block.isEmpty {
            let whole = block + "\n\n"
            let middle = whole.index(whole.startIndex, offsetBy: whole.count / 2)
            out.append(String(whole[..<middle]))
            out.append(String(whole[middle...]))
        }
        return out
    }

    // MARK: - Scripts

    private static let searchToolCallScript = #"""
    data: {"id":"chatcmpl-mock-search-01","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-search-01","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_mock_search_1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"latest iOS updates\"}"}}]},"finish_reason":"tool_calls"}]}

    data: {"id":"chatcmpl-mock-search-01","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[],"usage":{"prompt_tokens":85,"completion_tokens":22,"total_tokens":107}}

    data: [DONE]

    """#

    private static let searchAnswerScript = #"""
    data: {"id":"chatcmpl-mock-search-02","object":"chat.completion.chunk","created":1756180005,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-search-02","object":"chat.completion.chunk","created":1756180005,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"Based on the latest search results, "},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-search-02","object":"chat.completion.chunk","created":1756180005,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"Swift 6 brings full strict concurrency guarantees [1].\n\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-search-02","object":"chat.completion.chunk","created":1756180005,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"Cloudflare AI Gateway routes all calls through an authenticated gateway [2]."},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-search-02","object":"chat.completion.chunk","created":1756180005,"model":"mock/sate-preview","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: {"id":"chatcmpl-mock-search-02","object":"chat.completion.chunk","created":1756180005,"model":"mock/sate-preview","choices":[],"usage":{"prompt_tokens":195,"completion_tokens":48,"total_tokens":243}}

    data: [DONE]

    """#

    private static let normalScript = #"""
    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"reasoning_content":"The user is running the offline mock. "},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"reasoning_content":"I should answer with enough markdown to exercise the renderer."},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"## Streaming"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":", end to end\n\nThis reply comes"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":" from the **offline mock**"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":", so no token and no network"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":" were involved. Everything else is real:\n\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"1. `SSEParser` frames the bytes"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":", chunk boundaries and all.\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"2. `ChatCompletionsCodec` decodes"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":" each payload into stream events.\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"3. `DeltaCoalescer` batches them"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":" before they reach the main actor.\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"4. The transcript is appended once"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":", at the end.\n\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"```swift\nfor try await event in client.stream(request) {\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"    handle(event)\n}\n```\n\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"Say *error*, *truncate* or *unauthorized*"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":" to see the failure paths. 🚀"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: {"id":"chatcmpl-mock-0001","object":"chat.completion.chunk","created":1756180000,"model":"mock/sate-preview","choices":[],"usage":{"prompt_tokens":142,"completion_tokens":186,"total_tokens":328}}

    data: [DONE]

    """#

    private static let truncatedScript = #"""
    data: {"id":"chatcmpl-mock-0002","object":"chat.completion.chunk","created":1756180010,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0002","object":"chat.completion.chunk","created":1756180010,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"Counting to a hundred:"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0002","object":"chat.completion.chunk","created":1756180010,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":" one, two, three, four,"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0002","object":"chat.completion.chunk","created":1756180010,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":" five, six, seven, eight,"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0002","object":"chat.completion.chunk","created":1756180010,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":" nine, ten, eleven, twe"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0002","object":"chat.completion.chunk","created":1756180010,"model":"mock/sate-preview","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}

    data: {"id":"chatcmpl-mock-0002","object":"chat.completion.chunk","created":1756180010,"model":"mock/sate-preview","choices":[],"usage":{"prompt_tokens":96,"completion_tokens":32,"total_tokens":128}}

    """#

    private static let errorScript = #"""
    data: {"id":"chatcmpl-mock-0003","object":"chat.completion.chunk","created":1756180020,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0003","object":"chat.completion.chunk","created":1756180020,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":"Let me look that up"},"finish_reason":null}]}

    data: {"id":"chatcmpl-mock-0003","object":"chat.completion.chunk","created":1756180020,"model":"mock/sate-preview","choices":[{"index":0,"delta":{"content":" for you — one moment"},"finish_reason":null}]}

    data: {"error":{"type":"overloaded_error","message":"Mock: the upstream provider is overloaded."}}

    """#
}
