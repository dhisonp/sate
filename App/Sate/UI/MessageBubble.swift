import SwiftUI
import UIKit

/// One committed turn.
///
/// `Equatable` so that a transcript re-render (new message appended, branch
/// switched) does not re-measure every earlier bubble — markdown block layout is
/// the expensive part and it is pure w.r.t. the message value.
struct MessageBubble: View, Equatable {
    let message: Message
    /// All messages sharing this message's parent, in append order. More than one
    /// means the user forked here and gets "‹ 2/3 ›" navigation.
    let siblings: [UUID]
    let onEdit: (Message) -> Void
    let onSwitchBranch: (UUID) -> Void

    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message && lhs.siblings == rhs.siblings
    }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            content
            metadata
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        // Only committed text is selectable: rapid updates make a selection
        // collapse and flicker, so the streaming view opts out.
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: 620, alignment: .trailing)
                // Long-press to edit-and-resend. This forks the conversation
                // rather than rewriting history (R2.2).
                .contextMenu {
                    Button {
                        onEdit(message)
                    } label: {
                        Label("Edit and Resend", systemImage: "pencil")
                    }
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                .accessibilityLabel("You said: \(message.text)")

        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(text: reasoning)
                }
                MarkdownBlocksView(source: message.text)
                    .equatable()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

        case .system, .tool:
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var metadata: some View {
        let tags = statusTags
        if !tags.isEmpty || siblings.count > 1 {
            HStack(spacing: 10) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if siblings.count > 1 {
                    SiblingNavigator(
                        siblings: siblings,
                        current: message.id,
                        onSwitch: onSwitchBranch
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: message.role == .user ? .trailing : .leading
            )
        }
    }

    /// Derived from the persisted finish reason, so a message recovered from an
    /// `.inflight` sidecar after a crash shows the same tag as a live cancel.
    private var statusTags: [String] {
        var tags: [String] = []
        if message.interrupted {
            tags.append("Interrupted")
        }
        switch message.finishReason {
        case .length: tags.append("Hit max length")
        case .contentFilter: tags.append("Filtered by provider")
        case .truncated: tags.append("May be incomplete")
        case .toolCalls: tags.append("Tool call")
        case let .unknown(raw): tags.append(raw)
        case .stop, .none: break
        }
        return tags
    }
}

/// "‹ 2/3 ›" at a fork. Switching the leaf is append-only in the store — nothing
/// is deleted, so stepping back and forth is lossless.
private struct SiblingNavigator: View {
    let siblings: [UUID]
    let current: UUID
    let onSwitch: (UUID) -> Void

    var body: some View {
        let index = siblings.firstIndex(of: current) ?? 0
        HStack(spacing: 6) {
            Button {
                if index > 0 {
                    onSwitch(siblings[index - 1])
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index == 0)
            .accessibilityLabel("Previous version")

            Text("\(index + 1)/\(siblings.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                if index + 1 < siblings.count {
                    onSwitch(siblings[index + 1])
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index == siblings.count - 1)
            .accessibilityLabel("Next version")
        }
        .font(.caption2)
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}

/// Reasoning is stored for display but never replayed to the model, so it is
/// collapsed by default to keep it visually out of the conversation proper.
private struct ReasoningDisclosure: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("Reasoning", systemImage: "brain")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
