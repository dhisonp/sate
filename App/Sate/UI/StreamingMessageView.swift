import SwiftUI

/// The in-flight assistant response.
///
/// This is the only view in the app that observes `Draft`. `ChatView`'s body must
/// never read `draft.text`: `@Observable` tracks reads per-body, so a parent that
/// touched the draft would re-evaluate the entire transcript at the flush cadence
/// (~60/s, with tokens arriving at up to 300/s).
///
/// Layout strategy: text laid out as one growing `Text` is O(n) to measure and is
/// re-measured on every flush, which is O(n²) across a response. Instead the text
/// is split into fence-aware paragraphs; every paragraph but the last is a frozen
/// `Text` with a stable id whose value has not changed, so SwiftUI skips it, and
/// only the trailing paragraph is re-laid out.
///
/// The trailing paragraph is plain text, not markdown: block re-parsing per flush
/// would defeat the point, and partially-typed syntax renders as noise. Full
/// markdown appears the instant the message commits into `MessageBubble`.
struct StreamingMessageView: View {
    let draft: Draft
    var isThinking: Bool = false

    var body: some View {
        let paragraphs = MarkdownParagraphs.split(draft.text)

        if !draft.isActive && paragraphs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                StreamingReasoningView(draft: draft)
                    .equatable()

                if draft.text.isEmpty {
                    ThinkingIndicator(draft: draft, isThinking: isThinking)
                        .padding(.vertical, 2)
                } else {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        if index == paragraphs.count - 1 {
                            // The only view that re-lays out on a token flush.
                            Text(paragraph)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            FrozenParagraph(text: paragraph)
                                .equatable()
                        }
                    }
                }
            }
            .font(.body)
            // Selection resets and flickers while the text mutates; committed
            // messages enable it instead.
            .textSelection(.disabled)
            // Without this VoiceOver re-reads the whole answer on every flush.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Assistant is responding")
            .accessibilityAddTraits(.updatesFrequently)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}

/// A paragraph that will never change again. `Equatable` conformance plus
/// `.equatable()` makes the "unchanged" case a single string comparison instead
/// of a body evaluation and a text re-measure.
private struct FrozenParagraph: View, Equatable {
    let text: String

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reasoning deltas arrive interleaved with text but change far less often.
/// Keeping them in their own view means a text flush does not re-lay out the
/// reasoning block, and vice versa. Equatable on identity: the enclosing view
/// re-creates this struct on every flush, and only real `reasoning` mutations
/// (tracked by `@Observable`) should invalidate it.
private struct StreamingReasoningView: View, Equatable {
    let draft: Draft

    nonisolated static func == (lhs: StreamingReasoningView, rhs: StreamingReasoningView) -> Bool {
        lhs.draft === rhs.draft
    }

    var body: some View {
        let reasoning = draft.reasoning
        if !reasoning.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Reasoning", systemImage: "brain")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(reasoning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
        }
    }
}

/// "Thinking… (Ns)". Driven by `draft.elapsedSeconds` (a 1 Hz timer owned by the
/// view model), never by socket activity — a model that is silently reasoning
/// still has to look alive. Isolated in its own view so the 1 Hz tick does not
/// invalidate `ChatView`.
struct ThinkingIndicator: View {
    let draft: Draft
    var isThinking: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let seconds = draft.elapsedSeconds
        let activeThinking = isThinking || !draft.reasoning.isEmpty
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label(for: seconds, isThinking: activeThinking))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        // No `maxWidth: .infinity`: the caller wraps this in a glass pill that
        // must hug its content rather than stretch across the screen.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label(for: seconds, isThinking: activeThinking))
        // No implicit animation on a per-second text change under Reduce Motion.
        .animation(reduceMotion ? nil : .default, value: seconds >= 60)
    }

    private func label(for seconds: Int, isThinking: Bool) -> String {
        // Past ~60 s the risk is a carrier or middlebox dropping an idle flow, so
        // the copy changes to set the expectation that this may not land.
        if isThinking {
            return seconds >= 60 ? "Still thinking… (\(seconds)s)" : "Thinking… (\(seconds)s)"
        } else {
            return seconds >= 60 ? "Still waiting… (\(seconds)s)" : "Waiting… (\(seconds)s)"
        }
    }
}
