import SwiftUI

/// This is the only view in the app that observes `Draft`. `ConversationView`'s body must
/// never read `draft.text`: `@Observable` tracks reads per-body, so a parent that
/// touched the draft would re-evaluate the entire transcript at the flush cadence
/// (~60/s, with tokens arriving at up to 300/s).
///
/// Markdown blocks are parsed on every flush. Each block is rendered in an
/// `Equatable` `MarkdownBlockView`, so SwiftUI skips re-evaluating preceding frozen
/// blocks and only re-lays out the trailing block in flight.
struct StreamingMessageView: View {
    let draft: Draft
    var isThinking: Bool = false
    var showThinking: Bool = true

    var body: some View {
        let text = draft.text
        let blocks = text.isEmpty ? [] : MarkdownBlockParser.parse(text)

        if !draft.isActive && blocks.isEmpty && (!showThinking || draft.reasoning.isEmpty) {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if showThinking {
                    StreamingReasoningView(draft: draft)
                        .equatable()
                }

                if text.isEmpty {
                    ThinkingIndicator(draft: draft, isThinking: isThinking)
                        .padding(.vertical, 2)
                } else {
                    ForEach(blocks) { block in
                        MarkdownBlockView(block: block, sources: nil)
                            .equatable()
                    }
                }
            }
            .font(.appSans(.body))
            .appLineSpacing(.body)
            // Selection resets and flickers while the text mutates; committed
            // messages enable it instead.
            .textSelection(.disabled)
            // Without this VoiceOver re-reads the whole answer on every flush.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Assistant is responding")
            .accessibilityAddTraits(.updatesFrequently)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    .font(.appSans(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(reasoning)
                    .font(.appSans(.callout))
                    .appLineSpacing(.callout)
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
/// invalidate `ConversationView`.
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
                .font(.appSans(.footnote))
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
