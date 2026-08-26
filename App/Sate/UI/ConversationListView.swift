import SwiftUI

/// Root screen: every conversation, newest first.
///
/// A `List` is fine here — unlike the transcript, these rows never mutate while
/// they are on screen, so self-sizing has nothing to re-measure.
struct ConversationListView: View {
    @Binding var path: [SateRoute]

    @Environment(AppEnvironment.self) private var env
    @State private var isCreating = false

    var body: some View {
        List {
            if env.recoveredCount > 0 {
                Section { recoveryBanner }
            }

            if env.conversations.isEmpty {
                Section { emptyState }
            } else {
                ForEach(env.conversations) { summary in
                    NavigationLink(value: SateRoute.chat(summary.id)) {
                        row(for: summary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await env.delete(summary.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sate")
        .refreshable { await env.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    path.append(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            // A visible reminder that nothing is hitting the real gateway; the
            // mock replays a bundled SSE fixture (SATE_MOCK=1).
            if env.isMock {
                ToolbarItem(placement: .principal) {
                    Text("MOCK")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        // A tint that means something: nothing here is hitting
                        // the real gateway.
                        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .capsule)
                        .accessibilityLabel("Mock gateway active")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    createConversation()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                .disabled(isCreating)
            }
        }
    }

    // MARK: Rows

    private func row(for summary: ConversationSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.title.isEmpty ? "New Conversation" : summary.title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(summary.model)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("·")
                Text(summary.updatedAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Banners

    /// Surfaced once at launch: an `.inflight` sidecar that survived a crash or a
    /// background expiry has been folded back in as an interrupted turn, so the
    /// tokens the user already paid for are not silently lost (R2.4).
    private var recoveryBanner: some View {
        Label(
            env.recoveredCount == 1
                ? "1 interrupted response recovered"
                : "\(env.recoveredCount) interrupted responses recovered",
            systemImage: "arrow.uturn.backward.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var emptyState: some View {
        if env.hasToken {
            ContentUnavailableView {
                Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Start one with the compose button.")
            } actions: {
                Button("New Conversation") { createConversation() }
                    .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        } else {
            ContentUnavailableView {
                Label("Set Up Cloudflare", systemImage: "key.horizontal")
            } description: {
                Text("""
                Sate talks only to your own Cloudflare AI Gateway. \
                Add your account ID, gateway ID, and an API token in Settings.

                The token needs both Account › Workers AI › Read and AI Gateway › Run.
                """)
            } actions: {
                Button("Open Settings") { path.append(.settings) }
                    .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Actions

    private func createConversation() {
        guard !isCreating else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            if let id = await env.newConversation() {
                path.append(.chat(id))
            }
        }
    }
}
