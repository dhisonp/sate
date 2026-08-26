import Foundation
import Testing

@testable import SateCore

// MARK: - URLProtocol stub

/// What the stub should do for one request.
struct StubResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = ["Content-Type": "text/event-stream"]
    /// Delivered as separate `didLoad:` calls so the client sees real chunk
    /// boundaries (events split mid-JSON, several events per chunk).
    var chunks: [Data] = []
    /// Fail the task with this instead of responding.
    var failure: URLError.Code?
    /// After the chunks, leave the response open instead of finishing — for
    /// cancellation tests. Nothing blocks: the loader simply never completes.
    var hang: Bool = false
    /// Never deliver even the response head. Models a send made with no route to
    /// the network while `waitsForConnectivity` is swallowing the URLError.
    var stall: Bool = false

    static func sse(_ chunks: [String], status: Int = 200) -> StubResponse {
        StubResponse(status: status, chunks: chunks.map { Data($0.utf8) })
    }

    static func body(_ text: String, status: Int, contentType: String, headers: [String: String] = [:])
        -> StubResponse
    {
        var all = ["Content-Type": contentType]
        all.merge(headers) { _, new in new }
        return StubResponse(status: status, headers: all, chunks: [Data(text.utf8)])
    }
}

/// Mutable state shared between the test thread and URLSession's loader thread.
final class StubBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) -> StubResponse)?
    private var recorded: [URLRequest] = []

    func install(_ handler: @escaping @Sendable (URLRequest) -> StubResponse) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        recorded.removeAll()
    }

    func respond(to request: URLRequest) -> StubResponse {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return handler?(request) ?? StubResponse()
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

/// One-bit flag readable from `startLoading`'s thread and writable from
/// `stopLoading`'s.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }
}

final class StubURLProtocol: URLProtocol {
    static let box = StubBox()
    private let flag = StopFlag()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.box.respond(to: request)
        guard let client else { return }

        if let failure = stub.failure {
            client.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        // Return without ever calling the client back: the task simply hangs, as
        // it does when URLSession is waiting for connectivity that never arrives.
        if stub.stall { return }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: stub.headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        for chunk in stub.chunks {
            if flag.isStopped { return }
            client.urlProtocol(self, didLoad: chunk)
            // Keeps chunks from coalescing in the loading system.
            Thread.sleep(forTimeInterval: 0.005)
        }
        if stub.hang || flag.isStopped { return }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        flag.stop()
    }
}

// MARK: - Suite

/// Serialized: the stub registry is process-global.
@Suite("GatewayClient", .serialized)
struct GatewayClientTests {
    static let configuration = GatewayConfiguration(
        accountID: "acct-1",
        gatewayID: "gw-1",
        token: "secret-token",
        // Keeps the single client-side retry from adding a second to the suite.
        retryDelayMilliseconds: 10,
        metadata: ["build": "42"])

    private func makeClient(
        _ configuration: GatewayConfiguration = GatewayClientTests.configuration,
        _ handler: @escaping @Sendable (URLRequest) -> StubResponse
    ) -> GatewayClient {
        StubURLProtocol.box.install(handler)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        return GatewayClient(
            configuration: configuration, session: URLSession(configuration: sessionConfiguration))
    }

    private func collect(
        _ stream: AsyncThrowingStream<StreamEvent, any Error>
    ) async -> (events: [StreamEvent], error: (any Error)?) {
        var events: [StreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
        } catch {
            return (events, error)
        }
        return (events, nil)
    }

    private func gatewayError(_ error: (any Error)?) throws -> GatewayError {
        try #require(error as? GatewayError)
    }

    private static let request = ChatCompletionRequest(
        model: "openai/gpt-5.2", messages: [.user("hello")], maxTokens: 256)

    // MARK: - Status mapping

    @Test("401 maps to unauthorized with the gateway's message")
    func unauthorized() async throws {
        let client = makeClient { _ in
            .body(#"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#,
                  status: 401, contentType: "application/json")
        }
        let (events, error) = await collect(client.stream(Self.request))
        #expect(events.isEmpty)
        #expect(try gatewayError(error) == .unauthorized(message: "Authentication error"))
        #expect(StubURLProtocol.box.requests.count == 1)
    }

    @Test("404 maps to notFound")
    func notFound() async throws {
        let client = makeClient { _ in
            .body(#"{"error":{"message":"model not found"}}"#, status: 404,
                  contentType: "application/json")
        }
        let (_, error) = await collect(client.stream(Self.request))
        #expect(try gatewayError(error) == .notFound(message: "model not found"))
    }

    @Test("429 carries retry-after and is never retried")
    func rateLimited() async throws {
        let client = makeClient { _ in
            .body(#"{"error":{"message":"rate limit"}}"#, status: 429,
                  contentType: "application/json", headers: ["retry-after": "5"])
        }
        let (_, error) = await collect(client.stream(Self.request))
        #expect(try gatewayError(error) == .rateLimited(retryAfter: 5, message: "rate limit"))
        #expect(StubURLProtocol.box.requests.count == 1)
    }

    @Test("500 maps to upstream")
    func upstream() async throws {
        let client = makeClient { _ in
            .body("internal error", status: 500, contentType: "text/plain")
        }
        let (_, error) = await collect(client.stream(Self.request))
        #expect(try gatewayError(error) == .upstream(status: 500, message: "internal error"))
    }

    @Test("524 with an HTML body maps to upstreamTimeout and is not retried")
    func edgeTimeoutIsNotRetried() async throws {
        let html = "<!DOCTYPE html><html><head><title>524: A timeout occurred</title></head></html>"
        let client = makeClient { _ in .body(html, status: 524, contentType: "text/html") }
        let (_, error) = await collect(client.stream(Self.request))
        let mapped = try gatewayError(error)
        guard case .upstreamTimeout(let status, let message) = mapped else {
            Issue.record("expected upstreamTimeout, got \(mapped)")
            return
        }
        #expect(status == 524)
        // The HTML body must survive as text — it must never reach a JSON decoder.
        #expect(message.contains("524"))
        #expect(StubURLProtocol.box.requests.count == 1)
    }

    @Test("503 before the first byte is retried exactly once, then surfaces")
    func gatewayUnavailableRetriesOnce() async throws {
        let client = makeClient { _ in
            .body(#"{"error":{"message":"no healthy upstream"}}"#, status: 503,
                  contentType: "application/json")
        }
        let (_, error) = await collect(client.stream(Self.request))
        #expect(try gatewayError(error)
            == .gatewayUnavailable(status: 503, message: "no healthy upstream"))
        #expect(StubURLProtocol.box.requests.count == 2)
        let trace = await client.lastTrace
        #expect(trace?.retried == true)
        #expect(trace?.statusCode == 503)
    }

    // MARK: - Streaming

    @Test("A chunked SSE stream decodes to ordered events ending in finished(.stop, usage)")
    func happyPath() async throws {
        let client = makeClient { _ in
            .sse([
                "data: {\"id\":\"resp_1\",\"model\":\"openai/gpt-5.2\",\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n",
                ": keepalive\n\ndata: {\"id\":\"resp_1\",\"choices\":[{\"delta\":{\"content\":\"Hel",
                "lo\"}}]}\n\ndata: {\"id\":\"resp_1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\r\n\r\n",
                "data: {\"id\":\"resp_1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
                "data: {\"id\":\"resp_1\",\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2,\"total_tokens\":11}}\n\n",
                "data: [DONE]\n\n",
            ])
        }
        let (events, error) = await collect(client.stream(Self.request, conversationID: UUID()))
        #expect(error == nil)
        #expect(events == [
            .started(responseID: "resp_1", model: "openai/gpt-5.2"),
            .textDelta("Hello"),
            .textDelta(" world"),
            .finished(
                reason: .stop,
                usage: Usage(promptTokens: 9, completionTokens: 2, totalTokens: 11)),
        ])
        let trace = await client.lastTrace
        #expect(trace?.statusCode == 200)
        #expect(trace?.route == "rest")
        #expect((trace?.bytesReceived ?? 0) > 0)
        #expect(trace?.timeToFirstByte != nil)
        #expect(trace?.retried == false)
    }

    // MARK: - Finish reason vs. usage trailer

    private static let sampleUsage = Usage(promptTokens: 9, completionTokens: 2, totalTokens: 11)

    private func finished(_ events: [StreamEvent]) throws -> (FinishReason, Usage?) {
        let terminal = events.compactMap { event -> (FinishReason, Usage?)? in
            if case .finished(let reason, let usage) = event { return (reason, usage) }
            return nil
        }
        #expect(terminal.count == 1, "exactly one terminal event must reach the caller")
        return try #require(terminal.first)
    }

    @Test("A usage trailer BEFORE the finish chunk does not mask finish_reason")
    func usageTrailerDoesNotMaskFinishReason() async throws {
        // The trailer says how much was billed, never why the answer ended. When
        // it arrived first, the reason was pinned to `.stop`: a truncated answer
        // persisted as a clean stop, the user was never told it was cut off, and
        // "Continue" never appeared.
        let client = makeClient { _ in
            .sse([
                "data: {\"id\":\"r\",\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n",
                "data: {\"id\":\"r\",\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2,\"total_tokens\":11}}\n\n",
                "data: {\"id\":\"r\",\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n",
                "data: [DONE]\n\n",
            ])
        }
        let (events, error) = await collect(client.stream(Self.request))
        #expect(error == nil)
        let (reason, usage) = try finished(events)
        #expect(reason == .length)
        // The trailer's usage must still survive into the terminal event.
        #expect(usage == Self.sampleUsage)
    }

    @Test("A usage trailer AFTER the finish chunk still attaches its usage")
    func usageTrailerAfterFinishReason() async throws {
        let client = makeClient { _ in
            .sse([
                "data: {\"id\":\"r\",\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n",
                "data: {\"id\":\"r\",\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}\n\n",
                "data: {\"id\":\"r\",\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2,\"total_tokens\":11}}\n\n",
                "data: [DONE]\n\n",
            ])
        }
        let (events, error) = await collect(client.stream(Self.request))
        #expect(error == nil)
        let (reason, usage) = try finished(events)
        #expect(reason == .contentFilter)
        #expect(usage == Self.sampleUsage)
    }

    @Test("Cumulative usage on every chunk still ends with the observed reason")
    func cumulativeUsageDoesNotPinTheReason() async throws {
        // Gemini through the compat translation reports usage on EVERY chunk, so
        // the placeholder reason used to win on the very first delta and pin every
        // single generation to `.stop`.
        let client = makeClient { _ in
            .sse([
                "data: {\"id\":\"r\",\"choices\":[{\"delta\":{\"content\":\"a\"}}],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":1,\"total_tokens\":10}}\n\n",
                "data: {\"id\":\"r\",\"choices\":[{\"delta\":{\"content\":\"b\"}}],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2,\"total_tokens\":11}}\n\n",
                "data: {\"id\":\"r\",\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2,\"total_tokens\":11}}\n\n",
                "data: [DONE]\n\n",
            ])
        }
        let (events, error) = await collect(client.stream(Self.request))
        #expect(error == nil)
        #expect(events.filter { if case .textDelta = $0 { return true } else { return false } }.count == 2)
        let (reason, usage) = try finished(events)
        #expect(reason == .length)
        // Last usage wins: a cumulative count grows chunk by chunk.
        #expect(usage == Self.sampleUsage)
    }

    @Test("Gateway response headers land in the trace")
    func traceHeaders() async throws {
        let client = makeClient { _ in
            StubResponse(
                status: 200,
                headers: [
                    "Content-Type": "text/event-stream",
                    "cf-aig-log-id": "log-123",
                    "cf-ray": "ray-abc",
                    "cf-aig-cache-status": "MISS",
                    "cf-aig-step": "1",
                ],
                chunks: [Data("data: {\"choices\":[{\"delta\":{\"content\":\"x\"},\"finish_reason\":\"stop\"}]}\n\n".utf8)])
        }
        _ = await collect(client.stream(Self.request))
        let trace = try #require(await client.lastTrace)
        #expect(trace.logID == "log-123")
        #expect(trace.ray == "ray-abc")
        #expect(trace.cacheStatus == "MISS")
        #expect(trace.step == 1)
    }

    @Test("A stream that ends without finish_reason finishes as truncated")
    func truncatedStream() async throws {
        let client = makeClient { _ in
            .sse([
                "data: {\"id\":\"r\",\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n"
            ])
        }
        let (events, error) = await collect(client.stream(Self.request))
        #expect(error == nil)
        #expect(events == [
            .started(responseID: "r", model: nil),
            .textDelta("partial"),
            .finished(reason: .truncated, usage: nil),
        ])
    }

    @Test("A 2xx application/json body degrades to one textDelta plus finished")
    func nonStreamingJSONResponse() async throws {
        let client = makeClient { _ in
            .body(#"""
            {"id":"cmpl_1","model":"openai/gpt-5.2","choices":[{"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}
            """#, status: 200, contentType: "application/json")
        }
        let (events, error) = await collect(client.stream(Self.request))
        #expect(error == nil)
        #expect(events == [
            .started(responseID: "cmpl_1", model: "openai/gpt-5.2"),
            .textDelta("Hi"),
            .finished(
                reason: .stop, usage: Usage(promptTokens: 3, completionTokens: 1, totalTokens: 4)),
        ])
    }

    @Test("A mid-stream error object surfaces after the deltas already delivered")
    func midStreamError() async throws {
        let client = makeClient { _ in
            .sse([
                "data: {\"id\":\"r\",\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n",
                "data: {\"error\":{\"message\":\"upstream exploded\",\"type\":\"server_error\"}}\n\n",
                "data: [DONE]\n\n",
            ])
        }
        let (events, error) = await collect(client.stream(Self.request))
        #expect(events == [
            .started(responseID: "r", model: nil),
            .textDelta("Hi"),
        ])
        #expect(try gatewayError(error)
            == .inStreamError(code: "server_error", message: "upstream exploded"))
    }

    // MARK: - Failure mapping

    @Test("URLError.cancelled maps to GatewayError.cancelled, not an error state")
    func cancelledURLErrorMapsToCancelled() async throws {
        let client = makeClient { _ in StubResponse(failure: .cancelled) }
        let (_, error) = await collect(client.stream(Self.request))
        #expect(try gatewayError(error) == .cancelled)
        // `.cancelled` is not retriable, so the request is not repeated.
        #expect(StubURLProtocol.box.requests.count == 1)
    }

    @Test("Offline and connection-loss map to their own cases")
    func networkErrorMapping() async throws {
        let offline = makeClient { _ in StubResponse(failure: .notConnectedToInternet) }
        #expect(try gatewayError(await collect(offline.stream(Self.request)).error) == .offline)

        let lost = makeClient { _ in StubResponse(failure: .networkConnectionLost) }
        #expect(try gatewayError(await collect(lost.stream(Self.request)).error)
            == .connectionLost(bytesReceived: 0))

        let idle = makeClient { _ in StubResponse(failure: .timedOut) }
        #expect(try gatewayError(await collect(idle.stream(Self.request)).error)
            == .idleTimeout(bytesReceived: 0))
    }

    @Test("A connect that never completes surfaces as offline within the budget")
    func connectivityBudgetSurfacesAsOffline() async throws {
        // `waitsForConnectivity` suppresses URLError.notConnectedToInternet, so an
        // offline send used to block until `timeoutIntervalForResource` (900 s) and
        // then arrive as a RETRIABLE `.idleTimeout` — half an hour of frozen
        // "Sending…" and "The model stopped responding." R1.1 budgets 10 s; the
        // test uses 150 ms of it.
        let configuration = GatewayConfiguration(
            accountID: "acct-1",
            token: "secret-token",
            retryDelayMilliseconds: 10,
            connectivityTimeout: 0.15)
        let client = makeClient(configuration) { _ in StubResponse(stall: true) }

        let started = Date()
        let (events, error) = await collect(client.stream(Self.request))
        let elapsed = Date().timeIntervalSince(started)

        #expect(events.isEmpty)
        #expect(try gatewayError(error) == .offline)
        // One retry is allowed before the first byte, so two budgets plus the
        // retry delay — still nowhere near the resource timeout.
        #expect(elapsed < 5, "took \(elapsed)s")
    }

    @Test("Cancelling the consuming task tears the request down promptly")
    func cancellationStopsTheRequest() async throws {
        let client = makeClient { _ in
            StubResponse(
                chunks: [Data("data: {\"id\":\"r\",\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n".utf8)],
                hang: true)
        }
        let started = Date()
        let work = Task {
            var deltas = 0
            for try await event in client.stream(Self.request) {
                if case .textDelta = event { deltas += 1 }
            }
            return deltas
        }
        // Let the first chunk land, then cancel while the response is still open.
        try? await Task.sleep(nanoseconds: 300_000_000)
        work.cancel()
        _ = try? await work.value
        // The generation must not outlive the consumer: a dismissed view that keeps
        // streaming is a billing bug, not just a leak.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("Missing configuration fails before any request is made")
    func notConfigured() async throws {
        let client = makeClient(GatewayConfiguration()) { _ in .sse([]) }
        let (_, error) = await collect(client.stream(Self.request))
        #expect(try gatewayError(error) == .notConfigured)
        #expect(StubURLProtocol.box.requests.isEmpty)
    }

    // MARK: - Outgoing request

    @Test("REST route uses Authorization and the gateway-id header")
    func restRequestHeaders() async throws {
        let client = makeClient { _ in .sse(["data: [DONE]\n\n"]) }
        _ = await collect(client.stream(Self.request, conversationID: nil))
        let sent = try #require(StubURLProtocol.box.requests.first)
        let headers = sent.allHTTPHeaderFields ?? [:]

        #expect(sent.url?.absoluteString
            == "https://api.cloudflare.com/client/v4/accounts/acct-1/ai/v1/chat/completions")
        #expect(headers["Authorization"] == "Bearer secret-token")
        #expect(headers["cf-aig-authorization"] == nil)
        #expect(headers["cf-aig-gateway-id"] == "gw-1")
        #expect(headers["Accept"] == "text/event-stream")
        #expect(headers["Content-Type"] == "application/json")
        // Compression buffers whole blocks and visibly delays tokens.
        #expect(headers["Accept-Encoding"] == "identity")
        #expect(headers["cf-aig-request-timeout"] == "180000")
        #expect(headers["cf-aig-max-attempts"] == "2")
        #expect(headers["cf-aig-retry-delay"] == "10")
        #expect(headers["cf-aig-backoff"] == "exponential")
        #expect(headers["cf-aig-collect-log-payload"] == nil)
        // No provider credential may ever leave the device.
        #expect(headers["x-api-key"] == nil)
    }

    @Test("A dynamic/* model picks the compat route and its auth header")
    func compatRequestHeaders() async throws {
        let client = makeClient { _ in .sse(["data: [DONE]\n\n"]) }
        let dynamic = ChatCompletionRequest(model: "dynamic/assistant", messages: [.user("hi")])
        _ = await collect(client.stream(dynamic, conversationID: nil))
        let sent = try #require(StubURLProtocol.box.requests.first)
        let headers = sent.allHTTPHeaderFields ?? [:]

        #expect(sent.url?.absoluteString
            == "https://gateway.ai.cloudflare.com/v1/acct-1/gw-1/compat/chat/completions")
        #expect(headers["cf-aig-authorization"] == "Bearer secret-token")
        #expect(headers["Authorization"] == nil)
        // The compat host encodes the gateway in the path, so the header is redundant.
        #expect(headers["cf-aig-gateway-id"] == nil)
        #expect(headers["Accept-Encoding"] == "identity")
    }

    @Test("Metadata is a JSON string of at most five keys")
    func metadataHeader() async throws {
        let configuration = GatewayConfiguration(
            accountID: "acct-1",
            token: "secret-token",
            collectLogPayload: false,
            metadata: ["build": "42", "device": "hashed", "a": "1", "b": "2", "c": "3", "d": "4"])
        let client = makeClient(configuration) { _ in .sse(["data: [DONE]\n\n"]) }
        let conversation = UUID()
        _ = await collect(client.stream(Self.request, conversationID: conversation))
        let sent = try #require(StubURLProtocol.box.requests.first)
        let headers = sent.allHTTPHeaderFields ?? [:]
        #expect(headers["cf-aig-collect-log-payload"] == "false")
        // No gateway id configured, so the REST default gateway is used.
        #expect(headers["cf-aig-gateway-id"] == nil)

        let raw = try #require(headers["cf-aig-metadata"])
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String])
        #expect(decoded.count == 5)
        #expect(decoded["app"] == "sate")
        #expect(decoded["conversation"] == conversation.uuidString)
    }

    @Test("The request body carries the encoded conversation")
    func requestBody() async throws {
        let client = makeClient { _ in .sse(["data: [DONE]\n\n"]) }
        _ = await collect(client.stream(Self.request))
        let sent = try #require(StubURLProtocol.box.requests.first)
        // URLSession hands a URLProtocol the body as a stream, not as httpBody.
        let data = sent.httpBody ?? Self.readStream(sent.httpBodyStream)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "openai/gpt-5.2")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 256)
        #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "hello"]])
        // The token belongs in a header and nowhere else.
        #expect(!String(decoding: data, as: UTF8.self).contains("secret-token"))
    }

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[..<read])
        }
        return data
    }
}
