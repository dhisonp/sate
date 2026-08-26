import Foundation

/// User-controlled reasoning effort sent with completion requests.
///
/// Default is `.off` so a fresh install never silently incurs extra latency or
/// token cost. Providers map this to their respective wire parameters via `ThinkingPolicy`.
public enum ThinkingLevel: String, Sendable, Codable, CaseIterable {
    case off
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}
