import Foundation
import OSLog

/// Process-wide app state: settings, the conversation list, the gateway client,
/// and the per-conversation sessions and view models.
///
/// Sessions live here rather than in a view so a generation survives navigation
/// (R2.8/R2.10) — switching conversations must never abort a paid-for response.
@MainActor
@Observable
final class AppEnvironment {
    private enum Key {
        static let settings = "sate.settings"
        /// The learned chars/token ratios. Kept out of `SateSettings` because it
        /// is measured, not configured, and the user never edits it.
        static let estimator = "sate.estimator"
    }

    @ObservationIgnored private var settingsWriteTask: Task<Void, Never>?

    var settings: SateSettings {
        didSet { debouncePersistSettings() }
    }

    private(set) var conversations: [ConversationSummary] = []
    /// Messages restored from `.inflight` sidecars at launch, so the UI can say
    /// what happened after a crash or a termination mid-stream.
    private(set) var recoveredCount: Int = 0

    /// Calibrated per-model token ratios, shared by every conversation.
    @ObservationIgnored private(set) var estimator: TokenEstimator
    @ObservationIgnored let store: ConversationStore
    /// Rebuilt whenever the account, gateway or token changes. Not observed: the
    /// UI never reads it, only `ConversationViewModel` does.
    @ObservationIgnored private(set) var client: any LLMStreaming

    let isMock: Bool

    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let defaults: UserDefaults
    /// One session per URLSession lifetime, reused by every rebuilt client so a
    /// settings edit does not leak a session (they are retained until invalidated).
    @ObservationIgnored private let urlSession: URLSession?
    @ObservationIgnored private var configurationSignature: String
    /// Cached so `hasToken` never touches the Keychain from a view's `body`.
    private var cachedToken: String?
    private var cachedSearchToken: String?
    @ObservationIgnored private var viewModels: [UUID: ConversationViewModel] = [:]
    @ObservationIgnored private var sessions: [UUID: ConversationRunner] = [:]

    var hasToken: Bool {
        guard let cachedToken else { return false }
        return !cachedToken.isEmpty
    }

    var hasSearchToken: Bool {
        guard let cachedSearchToken else { return false }
        return !cachedSearchToken.isEmpty
    }

    init(
        settings: SateSettings,
        estimator: TokenEstimator,
        store: ConversationStore,
        secrets: any SecretStore,
        defaults: UserDefaults,
        isMock: Bool,
        cachedToken: String? = nil,
        cachedSearchToken: String? = nil
    ) {
        self.settings = settings
        self.estimator = estimator
        self.store = store
        self.secrets = secrets
        self.defaults = defaults
        self.isMock = isMock
        self.cachedToken = cachedToken
        self.cachedSearchToken = cachedSearchToken
        urlSession = isMock ? nil : AppEnvironment.makeURLSession()
        if isMock {
            client = MockGatewayClient()
            configurationSignature = "mock"
        } else {
            let configuration = AppEnvironment.configuration(
                settings: settings, token: cachedToken ?? ""
            )
            client = GatewayClient(configuration: configuration, session: urlSession)
            configurationSignature = AppEnvironment.signature(configuration)
        }
    }

    static func live() -> AppEnvironment {
        let isMock = ProcessInfo.processInfo.environment["SATE_MOCK"] == "1"
        let defaults = UserDefaults.standard

        var settings = SateSettings()
        if let data = defaults.data(forKey: Key.settings),
           let decoded = try? JSONDecoder().decode(SateSettings.self, from: data)
        {
            settings = decoded
        }
        var estimator = TokenEstimator()
        if let data = defaults.data(forKey: Key.estimator),
           let decoded = try? JSONDecoder().decode(TokenEstimator.self, from: data)
        {
            estimator = decoded
        }

        let store = ConversationStore(directory: conversationsDirectory())
        // The mock path must work with no Keychain entry and no network, so it
        // gets stand-in tokens purely to satisfy `hasToken` and `hasSearchToken`.
        let secrets: any SecretStore = isMock
            ? InMemorySecretStore(token: "mock-token", searchToken: "mock-search-token")
            : KeychainSecretStore()

        return AppEnvironment(
            settings: settings,
            estimator: estimator,
            store: store,
            secrets: secrets,
            defaults: defaults,
            isMock: isMock
        )
    }

    func bootstrap() async {
        Log.lifecycle.info("Bootstrap started")

        if !isMock {
            let tokens = await Task.detached { [secrets] in
                (try? secrets.token(), try? secrets.searchToken())
            }.value
            guard !Task.isCancelled else { return }
            cachedToken = tokens.0
            cachedSearchToken = tokens.1
            rebuildClientIfNeeded()
        }

        let recovered: [UUID]
        if let hasCheckpoints = try? await store.hasCheckpoints(), hasCheckpoints {
            recovered = (try? await store.recoverCheckpoints()) ?? []
        } else {
            recovered = []
        }
        let recoveredCount = recovered.count
        self.recoveredCount = recoveredCount
        if recoveredCount > 0 {
            Log.lifecycle.notice("Recovered \(recoveredCount) inflight checkpoint(s)")
        }
        await refresh()
        let conversationCount = conversations.count
        Log.lifecycle.info("Bootstrap complete: \(conversationCount) conversations loaded")
    }

    func refresh() async {
        conversations = (try? await store.list()) ?? []
    }

    func newConversation() async -> UUID? {
        guard let header = try? await store.create(
            title: "New Conversation", model: settings.defaultModel
        )
        else {
            Log.lifecycle.error("Failed to create new conversation")
            return nil
        }
        Log.lifecycle.info("Created new conversation \(header.conversationID, privacy: .public)")

        let summary = ConversationSummary(
            id: header.conversationID,
            title: header.title,
            model: header.model,
            updatedAt: header.createdAt,
            messageCount: 0
        )
        let index = conversations.firstIndex { existing in
            if existing.updatedAt != summary.updatedAt {
                return existing.updatedAt < summary.updatedAt
            }
            return existing.id.uuidString < summary.id.uuidString
        } ?? conversations.endIndex
        conversations.insert(summary, at: index)
        return header.conversationID
    }

    func delete(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        Log.lifecycle.info("Deleting \(ids.count) conversation(s)")
        for id in ids {
            if let session = sessions[id] {
                // Stop the generation before the file goes away, otherwise its commit
                // would fail against a deleted transcript.
                await session.cancelAndWait()
            }
            sessions[id] = nil
            viewModels[id] = nil
            do {
                try await store.delete(id)
            } catch {
                Log.persist.error("Failed to delete conversation \(id, privacy: .public): \(error, privacy: .public)")
            }
        }
        await refresh()
    }

    func delete(_ id: UUID) async {
        await delete([id])
    }

    func rename(_ id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await store.update(title: trimmed, model: nil, for: id)
        } catch {
            Log.persist.error("Failed to rename conversation \(id, privacy: .public): \(error, privacy: .public)")
        }
        if let existing = viewModels[id] {
            existing.title = trimmed
        }
        await refresh()
    }

    func deleteAll() async {
        let allIDs = Set(conversations.map(\.id)).union(sessions.keys).union(viewModels.keys)
        await delete(allIDs)
    }

    func viewModel(for id: UUID) -> ConversationViewModel {
        if let existing = viewModels[id] {
            return existing
        }
        let session = sessions[id] ?? ConversationRunner(conversationID: id, store: store)
        sessions[id] = session
        let model = ConversationViewModel(
            conversationID: id, store: store, session: session, environment: self
        )
        viewModels[id] = model
        return model
    }

    /// Evicts idle view models and sessions when navigating away from a conversation,
    /// bounding memory usage while keeping active background generations alive.
    func evictIdleViewModel(for id: UUID) {
        if let existing = viewModels[id], existing.phase.isBusy {
            Log.lifecycle.debug(
                "Skipping eviction for conversation \(id, privacy: .public): generation in flight"
            )
            return
        }
        viewModels[id] = nil
        Log.lifecycle.debug("Evicted idle view model for conversation \(id, privacy: .public)")
        if let session = sessions[id] {
            Task { [weak self] in
                let generating = await session.isGenerating
                guard !generating else { return }
                self?.sessions[id] = nil
                Log.lifecycle.debug("Evicted idle session for conversation \(id, privacy: .public)")
            }
        }
    }

    /// Forwards a scene change to EVERY live conversation, not just the one on
    /// screen. A generation started in one conversation keeps running after the
    /// user navigates back to the list — it is owned by the session, not the
    /// view — so scoping this to the visible conversation would leave that
    /// stream with no background-task grace and no deliberate commit when iOS
    /// suspends the process.
    func handleScenePhase(_ isActive: Bool) {
        let viewModelCount = viewModels.count
        Log.lifecycle.info("Handling scenePhase isActive=\(isActive) for \(viewModelCount) cached view models")
        for model in viewModels.values {
            model.handleScenePhase(isActive)
        }
    }

    func setToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try secrets.setToken(value)
        cachedToken = value
        rebuildClientIfNeeded()
    }

    func token() -> String? {
        cachedToken
    }

    func setSearchToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try secrets.setSearchToken(value)
        cachedSearchToken = value
    }

    func searchToken() -> String? {
        cachedSearchToken
    }

    func makeSearchProvider() -> (any SearchProvider)? {
        if isMock {
            return MockSearchProvider()
        }
        guard let token = searchToken(), !token.isEmpty else {
            return nil
        }
        return TavilySearchProvider(apiKey: token)
    }

    func calibrate(model: String, characters: Int, promptTokens: Int) {
        estimator.calibrate(model: model, characters: characters, promptTokens: promptTokens)
        if let data = try? JSONEncoder().encode(estimator) {
            defaults.set(data, forKey: Key.estimator)
        }
    }

    private func debouncePersistSettings() {
        settingsWriteTask?.cancel()
        settingsWriteTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            persistSettings()
        }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Key.settings)
        }
        rebuildClientIfNeeded()
    }

    /// Only rebuilds when something the client actually reads has changed: a new
    /// `GatewayClient` per keystroke in Settings would churn for nothing.
    private func rebuildClientIfNeeded() {
        guard !isMock else { return }
        let configuration = AppEnvironment.configuration(
            settings: settings, token: cachedToken ?? ""
        )
        let signature = AppEnvironment.signature(configuration)
        guard signature != configurationSignature else { return }
        Log.network.info("Rebuilding GatewayClient: configuration signature changed")
        configurationSignature = signature
        client = GatewayClient(configuration: configuration, session: urlSession)
    }

    private static func configuration(settings: SateSettings, token: String) -> GatewayConfiguration {
        GatewayConfiguration(
            accountID: settings.accountID.trimmingCharacters(in: .whitespacesAndNewlines),
            gatewayID: settings.gatewayID.isEmpty ? nil : settings.gatewayID,
            token: token,
            collectLogPayload: settings.collectLogPayload
        )
    }

    /// Identity without the token itself — only whether one is present and how it
    /// changed, so nothing that could leak a secret is kept around.
    private static func signature(_ configuration: GatewayConfiguration) -> String {
        [
            configuration.accountID,
            configuration.gatewayID ?? "",
            tokenFingerprint(configuration.token),
            String(configuration.collectLogPayload),
        ].joined(separator: "|")
    }

    private static func tokenFingerprint(_ token: String) -> String {
        guard !token.isEmpty else { return "0" }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// One session for the whole process. `GatewayClient` would happily make its
    /// own, but it is rebuilt on every settings change and `URLSession` retains
    /// itself until invalidated.
    private static func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }

    private static func conversationsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        let directory = base.appending(path: "Sate/Conversations", directoryHint: .isDirectory)
        // `.completeUntilFirstUserAuthentication`, not `.complete`: an append that
        // lands after the device locks must not fail mid-stream.
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return directory
    }
}
