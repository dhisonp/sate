import Foundation

/// Everything the user can configure except API tokens, which live in a
/// `SecretStore`. Decoding uses `decodeIfPresent` for every key so a settings blob
/// written by an older build (or an older blob read by a newer build with new
/// fields) still loads instead of bricking the app into a fresh-install state.
public struct SateSettings: Codable, Sendable, Hashable {
    public var accountID: String
    public var gatewayID: String
    /// A `ModelCatalog` id, or any free-form `provider/model` string the gateway
    /// resolves. The picker offers the catalog and keeps a Custom row for the rest.
    public var defaultModel: String
    /// Separate, cheap model used for auto-titling a conversation, so titling
    /// never burns frontier tokens. User-editable like any other model string.
    public var titleModel: String
    public var systemPrompt: String
    /// System prompt used when web search is enabled.
    public var systemPromptWithSearch: String
    /// `nil` means "omit the field" and let the provider default apply, which is
    /// not the same as sending 0.
    public var temperature: Double?
    /// User-controlled reasoning effort sent with completion requests. Default is `.off`.
    public var thinkingLevel: ThinkingLevel
    /// Always sent: several providers default to a small or unbounded value, and
    /// the reserve in `ContextWindow` is only meaningful if the cap is explicit.
    public var maxTokens: Int
    /// `stream_options.include_usage` — without it there is no `prompt_tokens` to
    /// calibrate the estimator from.
    public var includeUsage: Bool
    /// `cf-aig-collect-log-payload`: keeps request/response bodies in the gateway
    /// log so a failed turn can be inspected in the dashboard.
    public var collectLogPayload: Bool
    public var contextWindows: [String: ContextWindow]
    public var showDebugPanel: Bool

    // Web Search Settings (R6)
    public var searchEnabledByDefault: Bool
    public var searchProvider: SearchProviderType
    public var maxSearchRounds: Int
    public var searchResultsPerQuery: Int
    public var alwaysSearchFirstTurn: Bool

    public init() {
        accountID = ""
        gatewayID = ""
        defaultModel = ModelCatalog.defaultChat.id
        titleModel = ModelCatalog.defaultTitle.id
        systemPrompt = SystemPrompt.generalAssistant
        systemPromptWithSearch = SystemPrompt.generalAssistantWithSearch
        temperature = nil
        thinkingLevel = .off
        maxTokens = 16384
        includeUsage = true
        collectLogPayload = true
        contextWindows = [:]
        showDebugPanel = false

        searchEnabledByDefault = false
        searchProvider = .tavily
        maxSearchRounds = 3
        searchResultsPerQuery = 5
        alwaysSearchFirstTurn = false
    }

    /// The token is deliberately not part of this check: it is in the Keychain and
    /// may be unavailable while the device is locked.
    public var isConfigured: Bool {
        !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Falls back to a default-sized window for a model the user has never tuned,
    /// which is the common case given free-form model strings.
    public func window(for model: String) -> ContextWindow {
        if let stored = contextWindows[model] {
            var window = stored
            // Stored keys are authoritative for the model name; a blob written
            // before the field existed decodes with an empty one.
            window.model = model
            return window
        }
        return ModelCatalog.window(for: model) ?? ContextWindow(model: model)
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, gatewayID, defaultModel, titleModel, systemPrompt, systemPromptWithSearch
        case temperature, thinkingLevel, maxTokens, includeUsage, collectLogPayload
        case contextWindows, showDebugPanel
        case searchEnabledByDefault, searchProvider, maxSearchRounds, searchResultsPerQuery, alwaysSearchFirstTurn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SateSettings()
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? defaults.accountID
        gatewayID = try container.decodeIfPresent(String.self, forKey: .gatewayID) ?? defaults.gatewayID
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? defaults.defaultModel
        titleModel = try container.decodeIfPresent(String.self, forKey: .titleModel) ?? defaults.titleModel
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? defaults.systemPrompt
        systemPromptWithSearch = try container.decodeIfPresent(String.self, forKey: .systemPromptWithSearch)
            ?? defaults.systemPromptWithSearch
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        thinkingLevel = try container.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
            ?? defaults.thinkingLevel
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? defaults.maxTokens
        includeUsage = try container.decodeIfPresent(Bool.self, forKey: .includeUsage) ?? defaults.includeUsage
        collectLogPayload = try container.decodeIfPresent(Bool.self, forKey: .collectLogPayload)
            ?? defaults.collectLogPayload
        contextWindows = try container.decodeIfPresent([String: ContextWindow].self, forKey: .contextWindows)
            ?? defaults.contextWindows
        showDebugPanel = try container.decodeIfPresent(Bool.self, forKey: .showDebugPanel) ?? defaults.showDebugPanel

        searchEnabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .searchEnabledByDefault)
            ?? defaults.searchEnabledByDefault
        searchProvider = try container.decodeIfPresent(SearchProviderType.self, forKey: .searchProvider)
            ?? defaults.searchProvider
        maxSearchRounds = try container.decodeIfPresent(Int.self, forKey: .maxSearchRounds) ?? defaults.maxSearchRounds
        searchResultsPerQuery = try container.decodeIfPresent(Int.self, forKey: .searchResultsPerQuery)
            ?? defaults.searchResultsPerQuery
        alwaysSearchFirstTurn = try container.decodeIfPresent(Bool.self, forKey: .alwaysSearchFirstTurn)
            ?? defaults.alwaysSearchFirstTurn
    }
}
