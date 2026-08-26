import Foundation

/// Everything the client needs to reach one operator's gateway. The token is
/// held here but never copied into a trace, a log line, or an error message.
public struct GatewayConfiguration: Sendable {
    public var accountID: String
    /// Optional on REST (Cloudflare falls back to the gateway named `default`),
    /// required for the compat host and therefore for `dynamic/*` models.
    public var gatewayID: String?
    public var token: String
    /// `cf-aig-request-timeout`. Time-to-FIRST-BYTE only: once a chunk arrives the
    /// gateway waits indefinitely, so `idleTimeout` is the sole mid-stream guard.
    public var requestTimeoutMilliseconds: Int
    /// `cf-aig-max-attempts` — gateway-side retries, which only help before the
    /// first byte. Capped at 5 by Cloudflare.
    public var maxAttempts: Int
    /// `cf-aig-retry-delay`, and also the base delay for the client's own single
    /// retry, so both knobs move together.
    public var retryDelayMilliseconds: Int
    public var backoff: String
    /// `false` sends `cf-aig-collect-log-payload: false` so prompts stay out of
    /// the gateway's stored logs.
    public var collectLogPayload: Bool
    /// Merged into `cf-aig-metadata` (Cloudflare caps it at 5 keys).
    public var metadata: [String: String]
    public var idleTimeout: TimeInterval
    public var resourceTimeout: TimeInterval

    public init(
        accountID: String = "",
        gatewayID: String? = nil,
        token: String = "",
        requestTimeoutMilliseconds: Int = 180_000,
        maxAttempts: Int = 2,
        retryDelayMilliseconds: Int = 1_000,
        backoff: String = "exponential",
        collectLogPayload: Bool = true,
        metadata: [String: String] = [:],
        idleTimeout: TimeInterval = 120,
        resourceTimeout: TimeInterval = 900
    ) {
        self.accountID = accountID
        self.gatewayID = gatewayID
        self.token = token
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.maxAttempts = maxAttempts
        self.retryDelayMilliseconds = retryDelayMilliseconds
        self.backoff = backoff
        self.collectLogPayload = collectLogPayload
        self.metadata = metadata
        self.idleTimeout = idleTimeout
        self.resourceTimeout = resourceTimeout
    }

    public var isConfigured: Bool {
        !accountID.isEmpty && !token.isEmpty
    }
}

/// The only surface the app layer sees. Every failure arrives as a `GatewayError`.
public protocol LLMStreaming: Sendable {
    func stream(
        _ request: ChatCompletionRequest, conversationID: UUID?
    ) -> AsyncThrowingStream<StreamEvent, any Error>
    var lastTrace: NetworkTrace? { get async }
}

extension LLMStreaming {
    public func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<StreamEvent, any Error> {
        stream(request, conversationID: nil)
    }
}

/// HTTP + SSE transport for Cloudflare AI Gateway.
///
/// The actor owns only the mutable trace; the streaming work runs `nonisolated`
/// on a detached task so the SSE parser can be a plain value type owned by that
/// task. Feeding bytes into an actor would be an executor hop per byte.
public actor GatewayClient: LLMStreaming {
    private let configuration: GatewayConfiguration
    private let codec = ChatCompletionsCodec()
    /// Readable from the nonisolated streaming task: `URLSession` is Sendable and
    /// documented thread-safe.
    private let session: URLSession

    /// Last completed (or failed) request's diagnostics, for the debug panel.
    /// Never contains the token.
    public private(set) var lastTrace: NetworkTrace?

    public init(configuration: GatewayConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? GatewayClient.makeSession(configuration)
    }

    private static func makeSession(_ configuration: GatewayConfiguration) -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.default
        // Responses are unique per request and often huge; caching them is pure
        // cost, and a cached SSE body would be a correctness bug.
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.waitsForConnectivity = true
        sessionConfiguration.timeoutIntervalForRequest = configuration.idleTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
        return URLSession(configuration: sessionConfiguration)
    }

    private func store(_ trace: NetworkTrace) {
        lastTrace = trace
    }

    // MARK: - Streaming

    public nonisolated func stream(
        _ request: ChatCompletionRequest, conversationID: UUID? = nil
    ) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                await self.run(request, conversationID: conversationID, continuation: continuation)
            }
            // A dismissed view must not keep the generation alive: terminating the
            // stream cancels the task, which cancels the URLSession task.
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private nonisolated func run(
        _ request: ChatCompletionRequest,
        conversationID: UUID?,
        continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
    ) async {
        let route = GatewayRoute.route(
            for: request.model, accountID: configuration.accountID, gatewayID: configuration.gatewayID)
        var trace = NetworkTrace(route: route.name, model: request.model)

        guard configuration.isConfigured else {
            await store(trace)
            continuation.finish(throwing: GatewayError.notConfigured)
            return
        }

        let urlRequest: URLRequest
        do {
            urlRequest = try makeRequest(request, route: route, conversationID: conversationID)
        } catch {
            await store(trace)
            continuation.finish(throwing: error as? GatewayError ?? .protocolError("\(error)"))
            return
        }

        var attempt = 0
        while true {
            do {
                trace = try await attemptStream(urlRequest, base: trace, continuation: continuation)
                await store(trace)
                continuation.finish()
                return
            } catch let failure as AttemptFailure {
                trace = failure.trace
                // One retry, only before the first byte: a request that produced
                // output was billed and partially delivered, and re-sending it is
                // not idempotent (the provider may have accepted the first try).
                let retriable = attempt == 0
                    && failure.trace.bytesReceived == 0
                    && failure.error.isRetriableBeforeFirstByte
                    && !Task.isCancelled
                guard retriable else {
                    await store(trace)
                    continuation.finish(throwing: failure.error)
                    return
                }
                attempt += 1
                trace.retried = true
                do {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds(for: request))
                } catch {
                    await store(trace)
                    continuation.finish(throwing: GatewayError.cancelled)
                    return
                }
            } catch {
                await store(trace)
                continuation.finish(throwing: GatewayError.protocolError("\(error)"))
                return
            }
        }
    }

    /// Base delay plus a deterministic offset derived from the model string, so
    /// two clients retrying together spread out without making tests flaky.
    private nonisolated func retryDelayNanoseconds(for request: ChatCompletionRequest) -> UInt64 {
        let base = max(0, configuration.retryDelayMilliseconds)
        let spread = request.model.utf8.reduce(0) { ($0 &+ Int($1)) % 101 }
        let jitter = base * spread / 1000
        return UInt64(base + jitter) * 1_000_000
    }

    // MARK: - Request construction

    private nonisolated func makeRequest(
        _ request: ChatCompletionRequest, route: GatewayRoute, conversationID: UUID?
    ) throws -> URLRequest {
        guard let url = route.url else { throw GatewayError.notConfigured }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try codec.encodeBody(request, stream: true)

        // The Cloudflare token goes in the header this route reserves for it; a
        // provider Authorization/x-api-key is never sent — BYOK supplies it, and
        // sending one breaks unified billing.
        urlRequest.setValue("Bearer \(configuration.token)", forHTTPHeaderField: route.authHeaderName)
        if case .rest = route, let gatewayID = configuration.gatewayID, !gatewayID.isEmpty {
            urlRequest.setValue(gatewayID, forHTTPHeaderField: GatewayHeader.gatewayID)
        }
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // URLSession's default gzip/br decoders buffer whole blocks and visibly
        // delay token delivery; identity trades bandwidth for latency.
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        urlRequest.setValue(
            String(configuration.requestTimeoutMilliseconds),
            forHTTPHeaderField: GatewayHeader.requestTimeout)
        urlRequest.setValue(
            String(configuration.maxAttempts), forHTTPHeaderField: GatewayHeader.maxAttempts)
        urlRequest.setValue(
            String(configuration.retryDelayMilliseconds), forHTTPHeaderField: GatewayHeader.retryDelay)
        urlRequest.setValue(configuration.backoff, forHTTPHeaderField: GatewayHeader.backoff)
        if !configuration.collectLogPayload {
            urlRequest.setValue("false", forHTTPHeaderField: GatewayHeader.collectLogPayload)
        }
        if let metadata = metadataHeader(conversationID: conversationID) {
            urlRequest.setValue(metadata, forHTTPHeaderField: GatewayHeader.metadata)
        }
        return urlRequest
    }

    /// `cf-aig-metadata` is a JSON string of at most 5 string values; extra keys
    /// are dropped deterministically (sorted) rather than risking a 400.
    private nonisolated func metadataHeader(conversationID: UUID?) -> String? {
        var pairs: [(String, String)] = [("app", "sate")]
        if let conversationID {
            pairs.append(("conversation", conversationID.uuidString))
        }
        for key in configuration.metadata.keys.sorted() where !pairs.contains(where: { $0.0 == key }) {
            guard let value = configuration.metadata[key] else { continue }
            pairs.append((key, value))
        }
        let capped = Dictionary(uniqueKeysWithValues: pairs.prefix(5))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(capped) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - One attempt

    /// Carries the partial trace out of a failed attempt so the retry decision can
    /// see `bytesReceived` and the debug panel keeps the gateway's log id.
    private struct AttemptFailure: Error {
        var error: GatewayError
        var trace: NetworkTrace
    }

    /// Coalesced terminal state. The codec reports a `.finished` for both the
    /// `finish_reason` chunk and the usage trailer; exactly one reaches the caller.
    private struct TerminalState {
        var reason: FinishReason?
        var usage: Usage?

        mutating func absorb(_ reason: FinishReason, _ usage: Usage?) {
            if self.reason == nil { self.reason = reason }
            if let usage { self.usage = usage }
        }
    }

    private nonisolated func attemptStream(
        _ urlRequest: URLRequest,
        base: NetworkTrace,
        continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
    ) async throws -> NetworkTrace {
        var trace = base
        trace.statusCode = nil
        trace.bytesReceived = 0
        trace.timeToFirstByte = nil
        let start = Date()

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            trace.duration = Date().timeIntervalSince(start)
            throw AttemptFailure(error: Self.map(error, bytesReceived: 0), trace: trace)
        }

        guard let http = response as? HTTPURLResponse else {
            trace.duration = Date().timeIntervalSince(start)
            throw AttemptFailure(
                error: .protocolError("Response was not HTTP"), trace: trace)
        }
        apply(http, to: &trace)
        // Status and Content-Type are settled BEFORE any byte is consumed: a 524
        // body is HTML, and handing that to a JSON decoder produces a useless
        // "unexpected character" instead of "the model timed out".
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        guard (200..<300).contains(http.statusCode) else {
            let body = await Self.collect(bytes, limit: 64 * 1024)
            trace.duration = Date().timeIntervalSince(start)
            throw AttemptFailure(
                error: Self.error(status: http.statusCode, headers: http, body: body),
                trace: trace)
        }

        // Only `cancel()` is called on it, from the cancellation handler below.
        let dataTask = bytes.task

        do {
            return try await withTaskCancellationHandler {
                if contentType.contains("text/event-stream") {
                    return try await streamSSE(
                        bytes, trace: trace, start: start, continuation: continuation)
                }
                // A model (or a gateway fallback) that ignored `stream: true`.
                return try await streamWholeBody(
                    bytes, trace: trace, start: start, continuation: continuation)
            } onCancel: {
                dataTask.cancel()
            }
        } catch let failure as AttemptFailure {
            throw failure
        } catch {
            var failed = trace
            failed.duration = Date().timeIntervalSince(start)
            throw AttemptFailure(error: Self.map(error, bytesReceived: trace.bytesReceived), trace: failed)
        }
    }

    private nonisolated func streamSSE(
        _ bytes: URLSession.AsyncBytes,
        trace: NetworkTrace,
        start: Date,
        continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
    ) async throws -> NetworkTrace {
        var trace = trace
        var parser = SSEParser()
        var terminal = TerminalState()
        var startedForwarded = false
        var buffer: [UInt8] = []
        buffer.reserveCapacity(4096)
        var done = false

        func drain() throws {
            guard !buffer.isEmpty else { return }
            let events = try parser.consume(buffer)
            buffer.removeAll(keepingCapacity: true)
            for event in events {
                if event.isTerminator { done = true; continue }
                for streamEvent in try codec.decode(dataPayload: event.data) {
                    switch streamEvent {
                    case .started:
                        guard !startedForwarded else { continue }
                        startedForwarded = true
                        continuation.yield(streamEvent)
                    case .finished(let reason, let usage):
                        terminal.absorb(reason, usage)
                    default:
                        continuation.yield(streamEvent)
                    }
                }
            }
        }

        do {
            // `AsyncBytes` vends one byte at a time, so bytes are re-batched here
            // and handed to the parser in slices. The flush trigger is a newline
            // (the only place framing can complete, so no token is ever delayed)
            // with a 4 KiB cap for a pathologically long single line.
            for try await byte in bytes {
                if trace.bytesReceived == 0 {
                    trace.timeToFirstByte = Date().timeIntervalSince(start)
                }
                trace.bytesReceived += 1
                buffer.append(byte)
                if byte == 0x0A || byte == 0x0D || buffer.count >= 4096 {
                    try drain()
                }
                if done { break }
            }
            try drain()
        } catch let error as GatewayError {
            trace.duration = Date().timeIntervalSince(start)
            throw AttemptFailure(error: error, trace: trace)
        } catch {
            trace.duration = Date().timeIntervalSince(start)
            throw AttemptFailure(
                error: Self.map(error, bytesReceived: trace.bytesReceived), trace: trace)
        }

        // An unterminated trailing event is discarded per the SSE spec; it also
        // means the answer is short, which `.truncated` below already reports.
        _ = parser.finish()
        trace.duration = Date().timeIntervalSince(start)
        // Completeness is keyed on `finish_reason`, never on `[DONE]`: plenty of
        // providers hang up without the sentinel after a clean finish.
        continuation.yield(.finished(reason: terminal.reason ?? .truncated, usage: terminal.usage))
        return trace
    }

    private nonisolated func streamWholeBody(
        _ bytes: URLSession.AsyncBytes,
        trace: NetworkTrace,
        start: Date,
        continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
    ) async throws -> NetworkTrace {
        var trace = trace
        var body: [UInt8] = []
        do {
            for try await byte in bytes {
                if body.isEmpty { trace.timeToFirstByte = Date().timeIntervalSince(start) }
                body.append(byte)
            }
        } catch {
            trace.bytesReceived = body.count
            trace.duration = Date().timeIntervalSince(start)
            throw AttemptFailure(error: Self.map(error, bytesReceived: body.count), trace: trace)
        }
        trace.bytesReceived = body.count
        trace.duration = Date().timeIntervalSince(start)

        var terminal = TerminalState()
        do {
            for event in try codec.decodeComplete(Data(body)) {
                if case .finished(let reason, let usage) = event {
                    terminal.absorb(reason, usage)
                } else {
                    continuation.yield(event)
                }
            }
        } catch let error as GatewayError {
            throw AttemptFailure(error: error, trace: trace)
        }
        continuation.yield(.finished(reason: terminal.reason ?? .truncated, usage: terminal.usage))
        return trace
    }

    // MARK: - Response mapping

    private nonisolated func apply(_ http: HTTPURLResponse, to trace: inout NetworkTrace) {
        trace.statusCode = http.statusCode
        trace.logID = http.value(forHTTPHeaderField: GatewayHeader.logID)
        trace.ray = http.value(forHTTPHeaderField: GatewayHeader.ray)
        trace.cacheStatus = http.value(forHTTPHeaderField: GatewayHeader.cacheStatus)
        trace.step = http.value(forHTTPHeaderField: GatewayHeader.step).flatMap(Int.init)
    }

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async -> Data {
        var body: [UInt8] = []
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= limit { break }
            }
        } catch {
            // A truncated or failed error body must never mask the status code.
        }
        return Data(body)
    }

    private static func error(status: Int, headers: HTTPURLResponse, body: Data) -> GatewayError {
        let message = self.message(from: body, contentType: headers.value(forHTTPHeaderField: "Content-Type"))
        switch status {
        case 400:
            return .badRequest(message: message)
        case 401, 403:
            return .unauthorized(message: message)
        case 404:
            return .notFound(message: message)
        case 429:
            let retryAfter = headers.value(forHTTPHeaderField: GatewayHeader.retryAfter)
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter, message: message)
        case 502, 503:
            return .gatewayUnavailable(status: status, message: message)
        case 504, 524:
            // Not retriable: the upstream request very likely completed and was
            // billed; only the edge gave up waiting.
            return .upstreamTimeout(status: status, message: message)
        default:
            return .upstream(status: status, message: message)
        }
    }

    /// Best-effort human message. JSON is mined for Cloudflare's `errors[]` or the
    /// OpenAI `error.message`; anything else (notably 52x HTML) is truncated text.
    private static func message(from body: Data, contentType: String?) -> String {
        let text = String(decoding: body, as: UTF8.self)
        if (contentType ?? "").lowercased().contains("json") || text.hasPrefix("{") {
            if let value = try? JSONDecoder().decode(JSONValue.self, from: body),
               case .object(let root) = value {
                if case .array(let errors)? = root["errors"], case .object(let first)? = errors.first,
                   let message = first["message"]?.stringValue {
                    return message
                }
                if case .object(let error)? = root["error"], let message = error["message"]?.stringValue {
                    return message
                }
                if let message = root["error"]?.stringValue { return message }
                if let message = root["message"]?.stringValue { return message }
            }
        }
        let condensed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(condensed.prefix(500))
    }

    private static func map(_ error: any Error, bytesReceived: Int) -> GatewayError {
        if let gatewayError = error as? GatewayError { return gatewayError }
        // Cancellation surfaces as CancellationError before the headers and as
        // URLError.cancelled after them; neither is a failure to report.
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else {
            return .connectionLost(bytesReceived: bytesReceived)
        }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .networkConnectionLost:
            return .connectionLost(bytesReceived: bytesReceived)
        case .timedOut:
            return .idleTimeout(bytesReceived: bytesReceived)
        default:
            if urlError.networkUnavailableReason != nil { return .offline }
            return .connectionLost(bytesReceived: bytesReceived)
        }
    }
}
