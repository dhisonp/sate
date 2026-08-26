import Foundation

// MARK: - Producer-side accumulation

/// Shared accumulator between the streaming loop and the trailing-flush timer.
///
/// A plain lock rather than an actor: `append` runs once per delta (hundreds per
/// second) and an actor would cost an executor hop each time, which is exactly
/// what the coalescer exists to avoid.
///
/// Both producers only ever *stage* text here; the main actor is the sole
/// consumer via `take()`. That is what makes ordering safe — two producers
/// hopping to the main actor independently could otherwise deliver flushes out
/// of order, and a response would render scrambled.
final class DeltaBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var coalescer: DeltaCoalescer
    private var readyText = ""
    private var readyReasoning = ""

    init(coalescer: DeltaCoalescer = DeltaCoalescer()) {
        self.coalescer = coalescer
    }

    /// Producer side. Returns true when a main-actor delivery should be scheduled.
    func append(text: String = "", reasoning: String = "") -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let flush = coalescer.append(text: text, reasoning: reasoning) else { return false }
        readyText += flush.text
        readyReasoning += flush.reasoning
        return true
    }

    /// Trailing timer and terminal drain: promotes whatever the cadence rule is
    /// still holding back. Returns true when there is something to deliver.
    func drainPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let flush = coalescer.drain() {
            readyText += flush.text
            readyReasoning += flush.reasoning
        }
        return !readyText.isEmpty || !readyReasoning.isEmpty
    }

    /// Main-actor side. Nil when another delivery already consumed everything.
    func take() -> DeltaCoalescer.Flush? {
        lock.lock()
        defer { lock.unlock() }
        guard !readyText.isEmpty || !readyReasoning.isEmpty else { return nil }
        let flush = DeltaCoalescer.Flush(text: readyText, reasoning: readyReasoning)
        readyText.removeAll(keepingCapacity: true)
        readyReasoning.removeAll(keepingCapacity: true)
        return flush
    }
}

// MARK: - Outcome

/// The single terminal result of one generation, delivered to the main actor
/// exactly once. `committed` is the assistant message already written to the
/// transcript — the view model does not persist anything itself.
struct GenerationOutcome: Sendable {
    var committed: Message?
    var finishReason: FinishReason?
    var usage: Usage?
    var error: GatewayError?
    var trace: NetworkTrace?
}

/// Main-actor callbacks a generation reports through. Passed as values rather
/// than a delegate so `ConversationSession` never holds the view model.
struct GenerationEvents: Sendable {
    var started: @MainActor @Sendable (_ responseID: String?, _ model: String?) -> Void
    /// The buffer is handed over rather than a `Flush` so the drain happens on
    /// the main actor — see `DeltaBuffer`.
    var flushed: @MainActor @Sendable (DeltaBuffer) -> Void
    var completed: @MainActor @Sendable (GenerationOutcome) -> Void

    init(
        started: @escaping @MainActor @Sendable (String?, String?) -> Void,
        flushed: @escaping @MainActor @Sendable (DeltaBuffer) -> Void,
        completed: @escaping @MainActor @Sendable (GenerationOutcome) -> Void
    ) {
        self.started = started
        self.flushed = flushed
        self.completed = completed
    }
}

// MARK: - Session

/// Owns the streaming `Task` for one conversation (R2.8).
///
/// The task lives here, held by `AppEnvironment`, and *not* in a SwiftUI `.task`:
/// `.task` is cancelled when the view disappears, so navigating back to the
/// conversation list would abort a response the user already paid for.
actor ConversationSession {
    /// Trailing-edge flush cadence. The coalescer holds back a delta that arrives
    /// less than ~16 ms after the last flush; if the model then pauses, that tail
    /// would sit unrendered until the next token. 50 ms is invisible to the eye
    /// and cheap enough to run for the whole length of a response.
    private static let trailingFlushNanoseconds: UInt64 = 50_000_000
    /// R2.4: at most one sidecar write every 2 s. More often stalls the stream on
    /// file I/O; less often risks losing a visible amount of paid-for text.
    private static let checkpointInterval: TimeInterval = 2

    nonisolated let conversationID: UUID
    private nonisolated let store: ConversationStore
    private var task: Task<Void, Never>?

    init(conversationID: UUID, store: ConversationStore) {
        self.conversationID = conversationID
        self.store = store
    }

    var isGenerating: Bool {
        task != nil
    }

    /// Starts a generation. Returns false when one is already in flight for this
    /// conversation (R2.10: max one).
    @discardableResult
    func start(
        request: ChatCompletionRequest,
        client: any LLMStreaming,
        parentID: UUID?,
        events: GenerationEvents
    ) -> Bool {
        guard task == nil else { return false }
        let conversationID = self.conversationID
        let store = self.store
        // Detached: the generation must outlive whatever view or task asked for
        // it, and the heavy per-delta loop must not run on this actor's executor.
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await Self.generate(
                request: request,
                client: client,
                parentID: parentID,
                conversationID: conversationID,
                store: store,
                events: events
            )
            // Cleared before the callback so `isGenerating` is already false when
            // the view model reacts and, e.g., immediately starts a retry.
            await self?.clearTask()
            await MainActor.run { events.completed(outcome) }
        }
        return true
    }

    /// Cooperative cancel. The partial is still committed — see `generate`.
    func cancel() {
        task?.cancel()
    }

    /// Cancels and waits for the commit to land. Used for fork-mid-stream
    /// (R2.5): cancel → commit interrupted → append new user node → regenerate.
    func cancelAndWait() async {
        guard let task else { return }
        task.cancel()
        await task.value
    }

    private func clearTask() {
        task = nil
    }

    // MARK: The generation itself

    /// `static` and therefore nonisolated: every delta is handled on the
    /// concurrent executor, with no hop to this actor and none to the main actor
    /// except when the coalescer says it is time to render.
    private static func generate(
        request: ChatCompletionRequest,
        client: any LLMStreaming,
        parentID: UUID?,
        conversationID: UUID,
        store: ConversationStore,
        events: GenerationEvents
    ) async -> GenerationOutcome {
        let buffer = DeltaBuffer()
        var text = ""
        var reasoning = ""
        var finishReason: FinishReason?
        var usage: Usage?
        var responseModel: String?
        var failure: GatewayError?
        var lastCheckpoint = Date()

        let ticker = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: trailingFlushNanoseconds)
                } catch {
                    return
                }
                guard buffer.drainPending() else { continue }
                await MainActor.run { events.flushed(buffer) }
            }
        }
        defer { ticker.cancel() }

        do {
            for try await event in client.stream(request, conversationID: conversationID) {
                switch event {
                case let .started(responseID, model):
                    responseModel = model
                    await MainActor.run { events.started(responseID, model) }
                case let .textDelta(delta):
                    text += delta
                    if buffer.append(text: delta) {
                        await MainActor.run { events.flushed(buffer) }
                    }
                case let .reasoningDelta(delta):
                    reasoning += delta
                    if buffer.append(reasoning: delta) {
                        await MainActor.run { events.flushed(buffer) }
                    }
                case .toolCallDelta:
                    // v1 does not execute tools; the event exists so an agent loop
                    // can be added without touching the transport.
                    continue
                case let .finished(reason, reported):
                    finishReason = reason
                    if let reported {
                        usage = reported
                    }
                }

                if Date().timeIntervalSince(lastCheckpoint) >= checkpointInterval,
                   !text.isEmpty || !reasoning.isEmpty
                {
                    lastCheckpoint = Date()
                    try? await store.checkpoint(
                        conversationID: conversationID,
                        parentID: parentID,
                        text: text,
                        reasoning: reasoning,
                        model: request.model
                    )
                }
            }
        } catch let error as GatewayError {
            failure = error
        } catch is CancellationError {
            failure = .cancelled
        } catch {
            failure = .protocolError("\(error)")
        }

        // `AsyncThrowingStream` finishes *normally* when its consumer is
        // cancelled, so cancellation has to be detected here rather than caught.
        if failure == nil, Task.isCancelled {
            failure = .cancelled
        }

        // Stop the timer before the terminal drain so the two cannot race to
        // schedule the same tail twice.
        ticker.cancel()
        if buffer.drainPending() {
            await MainActor.run { events.flushed(buffer) }
        }

        var outcome = GenerationOutcome(
            finishReason: finishReason,
            usage: usage,
            error: failure,
            trace: await client.lastTrace
        )

        let clean = failure == nil && (finishReason?.isClean ?? false)
        if !text.isEmpty || !reasoning.isEmpty {
            let message = Message(
                parentID: parentID,
                role: .assistant,
                content: [.text(text)],
                reasoning: reasoning.isEmpty ? nil : reasoning,
                model: responseModel ?? request.model,
                finishReason: finishReason ?? .truncated,
                usage: usage,
                interrupted: !clean,
                logID: outcome.trace?.logID
            )
            do {
                // `append` deletes the in-flight sidecar in the same actor turn,
                // so nothing here may clear it again: a second delete could race
                // a *newer* generation's checkpoint.
                try await store.append(message, to: conversationID)
                outcome.committed = message
            } catch {
                outcome.error = outcome.error ?? .protocolError("The response could not be saved.")
            }
        } else {
            // Nothing was generated (rejected before the first byte, or cancelled
            // while still connecting): no empty assistant turn, just drop the
            // sidecar so launch recovery does not resurrect it.
            try? await store.clearCheckpoint(conversationID)
        }
        return outcome
    }
}
