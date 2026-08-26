import Foundation

/// Every failure the app can show, already mapped out of URLError / HTTP status /
/// SSE payload. The app layer must never inspect a raw `URLError`.
public enum GatewayError: Error, Hashable, Sendable {
    case notConfigured
    case offline
    /// Connection dropped. `bytesReceived > 0` forbids an automatic retry: the
    /// generation was partially billed and partially delivered.
    case connectionLost(bytesReceived: Int)
    case idleTimeout(bytesReceived: Int)
    case cancelled

    /// 401/403 — invalid token, or a token missing one of the two required scopes.
    case unauthorized(message: String)
    /// 404 — wrong account id, gateway id, or model string.
    case notFound(message: String)
    /// 400 — schema or context-length rejection from gateway or provider.
    case badRequest(message: String)
    /// 429 — rate limit or spend limit. Never auto-retried.
    case rateLimited(retryAfter: TimeInterval?, message: String)
    /// 502/503 — transient gateway failure, safe to retry only before first byte.
    case gatewayUnavailable(status: Int, message: String)
    /// 504/524 and other 5xx — the request may have completed and been billed
    /// upstream, so it must NOT be retried automatically.
    case upstreamTimeout(status: Int, message: String)
    case upstream(status: Int, message: String)

    /// Malformed SSE framing or undecodable JSON payload.
    case protocolError(String)
    /// HTTP 200 carrying `{"error": {...}}` inside the stream.
    case inStreamError(code: String?, message: String)

    public var isRetriableBeforeFirstByte: Bool {
        switch self {
        case .offline, .connectionLost, .idleTimeout, .gatewayUnavailable:
            return true
        default:
            return false
        }
    }
}

public extension GatewayError {
    /// Short, user-facing sentence. The debug panel shows the underlying detail.
    var userMessage: String {
        switch self {
        case .notConfigured:
            return "Add your Cloudflare account ID and token in Settings."
        case .offline:
            return "You're offline."
        case let .connectionLost(bytes):
            return bytes > 0 ? "Connection lost mid-response." : "Connection lost."
        case .idleTimeout:
            return "The model stopped responding."
        case .cancelled:
            return "Stopped."
        case .unauthorized:
            return "Cloudflare rejected the token. Check it is valid and has both Workers AI Read and AI Gateway Run."
        case let .notFound(message):
            return "Not found — check the account, gateway, and model. \(message)"
        case let .badRequest(message):
            return message.isEmpty ? "The request was rejected." : message
        case let .rateLimited(retryAfter, _):
            if let retryAfter {
                return "Rate or spend limit reached. Try again in \(Int(retryAfter))s."
            }
            return "Rate or spend limit reached."
        case let .gatewayUnavailable(status, _):
            return "Gateway error (\(status))."
        case .upstreamTimeout:
            return "The model took too long to start responding. It may still have been billed."
        case let .upstream(status, _):
            return "Provider error (\(status))."
        case .protocolError:
            return "The response could not be read."
        case let .inStreamError(_, message):
            return message
        }
    }
}
