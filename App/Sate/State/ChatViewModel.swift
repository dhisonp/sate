import Foundation

/// The send/stream state machine (R2.8). `awaitingFirstToken` is separate from
/// `sending` because that is the only window where "Thinking… (Ns)" is honest —
/// the request is accepted and the model is silent.
enum ChatPhase: Equatable {
    case idle
    case sending
    case searching(String)
    case awaitingFirstToken
    case streaming
    /// A partial answer was committed: cancelled, dropped, backgrounded, or
    /// stopped at `max_tokens`.
    case interrupted
    case failed(GatewayError)

    var isBusy: Bool {
        switch self {
        case .sending, .searching, .awaitingFirstToken, .streaming: return true
        case .idle, .interrupted, .failed: return false
        }
    }
}

/// One open conversation, projected for the UI. Owns no networking and no files:
/// it drives a `ConversationSession` and reads back what that session committed.
@MainActor
@Observable
final class ChatViewModel {
    let conversationID: UUID

    /// Committed turns on the current branch only. The in-flight response is in
    /// `draft` until the session commits it.
    private(set) var messages: [Message] = []
    let draft = Draft()
    private(set) var phase: ChatPhase = .idle
    var input: String = ""
    var isSearchEnabled: Bool
    private(set) var title: String
    var model: String {
        didSet {
            guard !isApplyingSnapshot, model != oldValue else { return }
            persistModel()
        }
    }

    private(set) var lastTrace: NetworkTrace?
    private(set) var lastError: GatewayError?

    /// Everything below is machinery the UI never reads; excluded so a mutation
    /// cannot invalidate a view.
    @ObservationIgnored private let store: ConversationStore
    @ObservationIgnored private let session: ConversationSession
    /// The environment owns this view model, so the back-reference is unowned.
    @ObservationIgnored private unowned let environment: AppEnvironment
    /// Full tree, kept in sync incrementally, so sibling navigation does not
    /// re-read the transcript on every render.
    @ObservationIgnored private var snapshot: ConversationSnapshot?
    @ObservationIgnored private var attempt: Attempt?
    @ObservationIgnored private var elapsedTicker: Task<Void, Never>?
    @ObservationIgnored private var backgroundGuard: BackgroundTaskGuard?
    @ObservationIgnored private var isApplyingSnapshot = false

    /// What was sent, so a context-length rejection can be re-trimmed and
    /// re-sent, and so the estimator can be calibrated against the exact payload
    /// the reported `prompt_tokens` describes.
    private struct Attempt {
        var request: ChatCompletionRequest
        var parentID: UUID?
        var branch: [Message]
        var shrunk: Bool
    }

    init(
        conversationID: UUID,
        store: ConversationStore,
        session: ConversationSession,
        environment: AppEnvironment
    ) {
        self.conversationID = conversationID
        self.store = store
        self.session = session
        self.environment = environment
        title = "New Conversation"
        model = environment.settings.defaultModel
        isSearchEnabled = environment.settings.searchEnabledByDefault
    }

    /// True when the newest assistant message can be continued.
    var canContinue: Bool {
        guard !phase.isBusy, let last = messages.last, last.role == .assistant else { return false }
        return last.interrupted || last.finishReason == .length
    }

    // MARK: - Loading

    func load() async {
        guard let snapshot = try? await store.load(conversationID) else { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: ConversationSnapshot) {
        self.snapshot = snapshot
        messages = snapshot.currentBranch
        title = snapshot.header.title
        isApplyingSnapshot = true
        model = snapshot.header.model
        isApplyingSnapshot = false
    }

    // MARK: - Sending

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !phase.isBusy else { return }
        input = ""
        guard let user = await commit(Message.user(text, parentID: messages.last?.id)) else {
            // The turn was never persisted, so the text belongs back in the field
            // rather than silently lost.
            input = text
            return
        }
        await titleIfNeeded(from: text)
        await run(parentID: user.id, branch: messages, shrunk: false)
    }

    func stop() {
        guard phase.isBusy else { return }
        Task { await session.cancel() }
    }

    /// Re-sends the last user turn. When an answer already exists for it this is
    /// a regeneration, which forks rather than overwrites.
    func retry() async {
        guard !phase.isBusy else { return }
        guard let last = messages.last else { return }
        if last.role == .user {
            await run(parentID: last.id, branch: messages, shrunk: false)
        } else {
            await regenerate()
        }
    }

    /// A new sibling answer for the same user turn. The previous answer is not
    /// deleted — the transcript is append-only and both remain navigable.
    func regenerate() async {
        guard !phase.isBusy else { return }
        guard let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        let branch = Array(messages[...index])
        let anchor = branch[index]
        if messages.count > branch.count {
            // Move the leaf back to the user turn first: if the app dies during
            // the regeneration, the next launch shows this branch, not the old
            // answer with an orphaned sibling hanging off it.
            try? await store.setLeaf(anchor.id, in: conversationID)
            messages = branch
            snapshot?.leafID = anchor.id
        }
        await run(parentID: anchor.id, branch: branch, shrunk: false)
    }

    /// R3.8: the partial is already committed as an assistant turn, so continuing
    /// is a plain user turn asking for the rest. No assistant prefill — current
    /// Anthropic models reject it.
    func continueGeneration() async {
        guard !phase.isBusy else { return }
        guard let last = messages.last, last.role == .assistant else { return }
        guard let user = await commit(
            Message.user("Continue exactly where you left off.", parentID: last.id)
        ) else { return }
        await run(parentID: user.id, branch: messages, shrunk: false)
    }

    /// Edit-and-resend: appends a sibling of the edited message under the same
    /// parent and answers that. The original branch stays reachable.
    func edit(_ messageID: UUID, newText: String) async {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let original = message(messageID), original.role == .user else { return }
        // Fork-mid-stream ordering (R2.5): cancel and let the interrupted partial
        // land before the new branch is appended.
        if phase.isBusy {
            await session.cancelAndWait()
        }

        if let parentID = original.parentID, let index = messages.firstIndex(where: { $0.id == parentID }) {
            messages = Array(messages[...index])
        } else if original.parentID == nil {
            messages = []
        }
        guard let user = await commit(
            Message(parentID: original.parentID, role: .user, content: [.text(text)])
        ) else { return }
        await run(parentID: user.id, branch: messages, shrunk: false)
    }

    // MARK: - Branches

    func siblings(of messageID: UUID) -> [UUID] {
        snapshot?.siblings(of: messageID) ?? []
    }

    func switchBranch(to messageID: UUID) async {
        guard !phase.isBusy else { return }
        guard let snapshot else { return }
        // Follow the branch down to its newest tip so switching to a sibling
        // restores the whole conversation under it, not just that one message.
        let leaf = deepestLeaf(from: messageID, in: snapshot)
        try? await store.setLeaf(leaf, in: conversationID)
        await load()
    }

    private func deepestLeaf(from id: UUID, in snapshot: ConversationSnapshot) -> UUID {
        var cursor = id
        var visited: Set<UUID> = [id]
        while let child = snapshot.childrenByParent[cursor]?.last, visited.insert(child).inserted {
            cursor = child
        }
        return cursor
    }

    // MARK: - Scene phase

    /// R4: a backgrounded stream gets ~25 s of grace, then is cancelled
    /// decisively — leaving the parser alive would let `URLSession` deliver a
    /// burst of buffered bytes into state that has already been committed.
    func handleScenePhase(_ isActive: Bool) {
        if isActive {
            backgroundGuard?.end()
            backgroundGuard = nil
            return
        }
        guard phase.isBusy, backgroundGuard == nil else { return }
        let guardian = BackgroundTaskGuard()
        backgroundGuard = guardian
        guardian.begin(name: "sate.generation") { [weak self] in
            guard let self else { return }
            self.backgroundGuard = nil
            // `stop()` commits whatever arrived, flagged interrupted.
            self.stop()
        }
    }

    // MARK: - Generation

    private func run(parentID: UUID?, branch: [Message], shrunk: Bool) async {
        lastError = nil
        phase = .sending
        draft.begin()
        startElapsedTicker()

        let settings = environment.settings
        let window = settings.window(for: model)
        let builder = ContextBuilder(estimator: environment.estimator)
        // Resolved per send, not when the prompt was saved: a prompt stored in
        // Settings weeks ago must still report today's date, or the model
        // reasons about "now" as of its training cutoff.
        let rawPrompt = isSearchEnabled ? settings.systemPromptWithSearch : settings.systemPrompt
        let systemPrompt = SystemPrompt.resolve(rawPrompt)
        let context = shrunk
            ? builder.rebuild(
                branch: branch, systemPrompt: systemPrompt, window: window, shrinkTo: 0.75
            )
            : builder.build(branch: branch, systemPrompt: systemPrompt, window: window)

        let thinkingExtra = ThinkingPolicy.extra(for: model, level: settings.thinkingLevel)
        // The builder already put the system prompt at the head of `messages`, so
        // passing it again here would send it twice.
        let request = ChatCompletionRequest(
            model: model,
            messages: context.messages,
            systemPrompt: nil,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature,
            includeUsage: settings.includeUsage,
            tools: isSearchEnabled ? [.webSearch] : nil,
            extra: thinkingExtra
        )
        attempt = Attempt(request: request, parentID: parentID, branch: branch, shrunk: shrunk)

        let searchProvider = isSearchEnabled ? environment.makeSearchProvider() : nil
        let started = await session.start(
            request: request,
            client: environment.client,
            searchProvider: searchProvider,
            searchEnabled: isSearchEnabled,
            maxSearchRounds: settings.maxSearchRounds,
            searchResultsPerQuery: settings.searchResultsPerQuery,
            parentID: parentID,
            events: makeEvents()
        )
        guard started else {
            // Another generation for this conversation is still running.
            stopElapsedTicker()
            draft.end()
            phase = .idle
            return
        }
    }

    private func makeEvents() -> GenerationEvents {
        GenerationEvents(
            started: { [weak self] responseID, model in
                self?.handleStarted(responseID: responseID, model: model)
            },
            searching: { [weak self] query in
                self?.handleSearching(query)
            },
            flushed: { [weak self] buffer in
                self?.handleFlush(buffer)
            },
            completed: { [weak self] outcome in
                self?.handleCompletion(outcome)
            }
        )
    }

    private func handleSearching(_ query: String) {
        phase = .searching(query)
    }

    private func handleStarted(responseID _: String?, model _: String?) {
        switch phase {
        case .sending, .searching:
            phase = .awaitingFirstToken
        default:
            break
        }
    }

    private func handleFlush(_ buffer: DeltaBuffer) {
        guard let flush = buffer.take() else { return }
        // A late tail can arrive after the terminal callback; it is already in the
        // committed message, so rendering it into the draft would duplicate it.
        guard draft.isActive else { return }
        if draft.firstTokenAt == nil {
            draft.firstTokenAt = Date()
        }
        draft.text += flush.text
        draft.reasoning += flush.reasoning
        if phase.isBusy, phase != .streaming {
            phase = .streaming
        }
    }

    private func handleCompletion(_ outcome: GenerationOutcome) {
        if let trace = outcome.trace {
            lastTrace = trace
        }
        stopElapsedTicker()

        // R4: a context-length 400 happens before anything is generated, so
        // re-trimming and re-sending once is safe and free of duplicate output.
        if let error = outcome.error,
           case let .badRequest(message) = error,
           ContextBuilder.isContextLengthError(message),
           outcome.committed == nil,
           let attempt, !attempt.shrunk
        {
            narrowWindow()
            Task { await self.run(parentID: attempt.parentID, branch: attempt.branch, shrunk: true) }
            return
        }

        if let message = outcome.committed {
            record(message)
        }
        calibrateEstimator(with: outcome)
        draft.end()

        switch outcome.error {
        case .none:
            phase = (outcome.committed?.interrupted ?? false) ? .interrupted : .idle
        case .some(.cancelled):
            // A deliberate stop is not a failure; the partial carries the tag.
            phase = .interrupted
        case let .some(error):
            lastError = error
            // A partial that reached disk is worth more than the error that ended
            // it: `.interrupted` offers Continue, which resumes from the partial,
            // while `.failed` offers only Retry — and Retry on an assistant turn
            // regenerates the whole answer and bills for it again. Dropping a
            // connection after 500 streamed tokens is the common case here.
            phase = outcome.committed != nil ? .interrupted : .failed(error)
        }
    }

    /// Folds the reported `prompt_tokens` back into the per-model chars/token
    /// ratio, using the exact text that was sent.
    private func calibrateEstimator(with outcome: GenerationOutcome) {
        guard let usage = outcome.usage, usage.promptTokens > 0, let attempt else { return }
        let characters = attempt.request.messages.reduce(0) { $0 + $1.text.count }
        environment.calibrate(model: model, characters: characters, promptTokens: usage.promptTokens)
    }

    /// After a context-length rejection, remember the smaller budget for this
    /// model so the next turn does not repeat the same wasted round trip.
    private func narrowWindow() {
        var window = environment.settings.window(for: model)
        let shrunk = Int(Double(window.effectiveBudgetTokens) * 0.75)
        window.inputBudgetTokens = max(shrunk, 1000) + window.reserveForOutputTokens
        environment.settings.contextWindows[model] = window
    }

    // MARK: - Persistence helpers

    @discardableResult
    private func commit(_ message: Message) async -> Message? {
        do {
            try await store.append(message, to: conversationID)
        } catch {
            let failure = GatewayError.protocolError("The message could not be saved.")
            lastError = failure
            phase = .failed(failure)
            return nil
        }
        record(message)
        return message
    }

    private func record(_ message: Message) {
        messages.append(message)
        snapshot?.messagesByID[message.id] = message
        snapshot?.childrenByParent[message.parentID, default: []].append(message.id)
        snapshot?.leafID = message.id
    }

    private func message(_ id: UUID) -> Message? {
        snapshot?.messagesByID[id] ?? messages.first { $0.id == id }
    }

    /// Names the conversation from its opening line. Deliberately local: titling
    /// through the model would spend tokens on every new thread, and the user can
    /// rename from the list.
    private func titleIfNeeded(from text: String) async {
        guard title == "New Conversation" || title.isEmpty else { return }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
        title = name
        try? await store.update(title: name, model: nil, for: conversationID)
        await environment.refresh()
    }

    private func persistModel() {
        let model = self.model
        Task {
            try? await store.update(title: nil, model: model, for: conversationID)
            await environment.refresh()
        }
    }

    // MARK: - Elapsed timer

    private func startElapsedTicker() {
        elapsedTicker?.cancel()
        elapsedTicker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard let self, self.draft.isActive, let startedAt = self.draft.startedAt else { return }
                self.draft.elapsedSeconds = Int(Date().timeIntervalSince(startedAt).rounded())
            }
        }
    }

    private func stopElapsedTicker() {
        elapsedTicker?.cancel()
        elapsedTicker = nil
    }
}
