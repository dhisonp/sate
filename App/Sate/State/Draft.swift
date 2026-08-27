import Foundation

/// Deliberately a tiny leaf object separate from `ConversationViewModel` (R2.8): it is
/// mutated on every coalescer flush, and a parent view that reads `phase` or
/// `messages` must not re-evaluate its `body` 60 times a second because of it.
/// Only `StreamingMessageView` observes this.
@MainActor
@Observable
final class Draft {
    /// Committed-so-far assistant text. Never a `Message` until the generation
    /// terminates — see `ConversationRunner`.
    var text: String = ""
    /// `reasoning_content` / `reasoning`, shown collapsed. Kept apart from `text`
    /// because it is display-only and is never replayed to the model.
    var reasoning: String = ""
    var isActive: Bool = false
    var startedAt: Date?
    var firstTokenAt: Date?
    /// Ticked ~1/s by `ConversationViewModel` so "Thinking… (12s)" is driven by a timer
    /// rather than by socket traffic — the whole point is that no bytes arrive.
    var elapsedSeconds: Int = 0

    init() {}

    var timeToFirstByte: TimeInterval? {
        guard let startedAt, let firstTokenAt else { return nil }
        return firstTokenAt.timeIntervalSince(startedAt)
    }

    /// Starts a new generation. Clears everything: a retry must not inherit the
    /// previous attempt's partial text.
    func begin(at instant: Date = Date()) {
        text = ""
        reasoning = ""
        isActive = true
        startedAt = instant
        firstTokenAt = nil
        elapsedSeconds = 0
    }

    /// The generation ended and its text now lives in a committed `Message`, so
    /// the draft must empty or the UI would render the answer twice.
    /// `startedAt`/`firstTokenAt` survive so the completion footer can still show
    /// the timing it just measured.
    func end() {
        text = ""
        reasoning = ""
        isActive = false
        elapsedSeconds = 0
    }
}
