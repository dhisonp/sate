import Foundation

/// The normalized vocabulary every transport reduces to. The app layer never
/// sees SSE, JSON, or Cloudflare — only this.
///
/// v1 does not execute tools, but `toolCallDelta` is modelled now so an agent
/// loop can be added without touching the networking layer.
public enum StreamEvent: Hashable, Sendable {
    /// First signal that the provider accepted the request.
    case started(responseID: String?, model: String?)
    case textDelta(String)
    /// `reasoning_content` (DeepSeek) or `reasoning` (xAI and others). May never
    /// arrive even for a thinking model — the compat layer can drop it.
    case reasoningDelta(String)
    /// Fragments join on `index`, not array position. `id` and `name` appear only
    /// in the first fragment of each call.
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String)
    /// Terminal. `usage` may be nil when the provider rejects `stream_options`.
    case finished(reason: FinishReason, usage: Usage?)
}

/// Everything the app wants to show in the debug panel and store alongside a
/// committed message for later correlation with Cloudflare's log viewer.
public struct NetworkTrace: Hashable, Sendable, Codable {
    public var route: String
    public var model: String
    public var statusCode: Int?
    /// `cf-aig-log-id` — the handle for finding this request in the dashboard.
    public var logID: String?
    /// `cf-ray` — present on edge errors (52x) where `cf-aig-log-id` is not.
    public var ray: String?
    /// `cf-aig-cache-status`: HIT | MISS.
    public var cacheStatus: String?
    /// `cf-aig-step`: > 0 means a fallback provider served the request.
    public var step: Int?
    public var timeToFirstByte: TimeInterval?
    public var duration: TimeInterval?
    public var bytesReceived: Int
    public var retried: Bool

    public init(
        route: String = "",
        model: String = "",
        statusCode: Int? = nil,
        logID: String? = nil,
        ray: String? = nil,
        cacheStatus: String? = nil,
        step: Int? = nil,
        timeToFirstByte: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        bytesReceived: Int = 0,
        retried: Bool = false
    ) {
        self.route = route
        self.model = model
        self.statusCode = statusCode
        self.logID = logID
        self.ray = ray
        self.cacheStatus = cacheStatus
        self.step = step
        self.timeToFirstByte = timeToFirstByte
        self.duration = duration
        self.bytesReceived = bytesReceived
        self.retried = retried
    }
}
