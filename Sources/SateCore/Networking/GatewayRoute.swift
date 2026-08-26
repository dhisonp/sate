import Foundation

/// A Cloudflare entry point: base URL + which header carries the token + which
/// token scope it needs. Modelled as a value rather than a boolean mode because
/// the two endpoints differ in host, auth header, and required permission, and
/// because the compat endpoint's deprecation timeline is unknown.
public enum GatewayRoute: Hashable, Sendable {
    /// Universal REST API. Requires `Account > Workers AI > Read`.
    case rest(accountID: String, gatewayID: String?)
    /// Legacy OpenAI-compat endpoint. The ONLY route that serves `dynamic/*`
    /// routes. Requires `AI Gateway > Run`.
    case compat(accountID: String, gatewayID: String)

    public var url: URL? {
        switch self {
        case .rest(let accountID, _):
            return URL(string:
                "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/v1/chat/completions")
        case .compat(let accountID, let gatewayID):
            return URL(string:
                "https://gateway.ai.cloudflare.com/v1/\(accountID)/\(gatewayID)/compat/chat/completions")
        }
    }

    /// REST uses the standard `Authorization`; the gateway host reserves that for
    /// provider credentials and takes the Cloudflare token in `cf-aig-authorization`.
    public var authHeaderName: String {
        switch self {
        case .rest: return "Authorization"
        case .compat: return "cf-aig-authorization"
        }
    }

    public var requiredTokenScope: String {
        switch self {
        case .rest: return "Account > Workers AI > Read"
        case .compat: return "AI Gateway > Run"
        }
    }

    public var supportsDynamicRoutes: Bool {
        if case .compat = self { return true }
        return false
    }

    public var name: String {
        switch self {
        case .rest: return "rest"
        case .compat: return "compat"
        }
    }

    /// `dynamic/*` model strings only resolve on the compat endpoint.
    public static func modelRequiresCompat(_ model: String) -> Bool {
        model.hasPrefix("dynamic/")
    }

    /// Picks the route for a model string, falling back to REST when no gateway
    /// id is configured for the compat host.
    public static func route(
        for model: String, accountID: String, gatewayID: String?
    ) -> GatewayRoute {
        if modelRequiresCompat(model), let gatewayID, !gatewayID.isEmpty {
            return .compat(accountID: accountID, gatewayID: gatewayID)
        }
        return .rest(accountID: accountID, gatewayID: gatewayID)
    }
}

/// Cloudflare request/response header names, in one place so no string literals
/// leak into call sites.
public enum GatewayHeader {
    public static let gatewayID = "cf-aig-gateway-id"
    public static let metadata = "cf-aig-metadata"
    public static let requestTimeout = "cf-aig-request-timeout"
    public static let maxAttempts = "cf-aig-max-attempts"
    public static let retryDelay = "cf-aig-retry-delay"
    public static let backoff = "cf-aig-backoff"
    public static let cacheTTL = "cf-aig-cache-ttl"
    public static let skipCache = "cf-aig-skip-cache"
    public static let collectLogPayload = "cf-aig-collect-log-payload"

    public static let logID = "cf-aig-log-id"
    public static let cacheStatus = "cf-aig-cache-status"
    public static let step = "cf-aig-step"
    public static let ray = "cf-ray"
    public static let retryAfter = "retry-after"
}
