import SwiftUI

/// Root screen: every conversation, newest first.
///
/// A `List` is fine here — unlike the transcript, these rows never mutate while
/// they are on screen, so self-sizing has nothing to re-measure.
struct ConversationListView: View {
    @Binding var path: [SateRoute]

    @Environment(AppEnvironment.self) private var env
    @State private var isCreating = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var isShowingBatchDeleteDialog = false
    @State private var isShowingDeleteAllDialog = false
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @FocusState private var isRenameFocused: Bool

    private var navigationTitle: String {
        guard editMode.isEditing else { return "" }
        return selectedIDs.isEmpty ? "Select Conversations" : "\(selectedIDs.count) Selected"
    }

    var body: some View {
        List(selection: $selectedIDs) {
            if env.recoveredCount > 0 && !editMode.isEditing {
                Section { recoveryBanner }
            }

            if env.conversations.isEmpty {
                Section { emptyState }
            } else {
                ForEach(env.conversations) { summary in
                    if renamingID == summary.id {
                        TextField("Title", text: $renameText)
                            .font(.appSans(.body))
                            .textFieldStyle(.plain)
                            .focused($isRenameFocused)
                            .submitLabel(.done)
                            .onSubmit {
                                commitRename(for: summary.id)
                            }
                    } else {
                        NavigationLink(value: SateRoute.conversation(summary.id)) {
                            row(for: summary)
                        }
                        .contextMenu {
                            Button {
                                renameText = summary.title
                                renamingID = summary.id
                                isRenameFocused = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                Task { await env.delete(summary.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
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
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .navigationTitle(navigationTitle)
        .refreshable { await env.refresh() }
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedIDs.count == env.conversations.count ? "Deselect All" : "Select All") {
                        if selectedIDs.count == env.conversations.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(env.conversations.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        editMode = .inactive
                        selectedIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(role: .destructive) {
                        isShowingDeleteAllDialog = true
                    } label: {
                        Text("Delete All")
                    }
                    .disabled(env.conversations.isEmpty)

                    Spacer()

                    Button(role: .destructive) {
                        isShowingBatchDeleteDialog = true
                    } label: {
                        Text(selectedIDs.isEmpty ? "Delete" : "Delete (\(selectedIDs.count))")
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            } else {
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
                            .font(.appSans(.caption2, weight: .bold))
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
                    Button("Edit") {
                        editMode = .active
                    }
                    .disabled(env.conversations.isEmpty)
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
        .confirmationDialog(
            "Delete \(selectedIDs.count) Conversation\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $isShowingBatchDeleteDialog,
            titleVisibility: .visible
        ) {
            Button(
                "Delete \(selectedIDs.count) Conversation\(selectedIDs.count == 1 ? "" : "s")",
                role: .destructive
            ) {
                let targets = selectedIDs
                selectedIDs.removeAll()
                Task {
                    await env.delete(targets)
                    if env.conversations.isEmpty {
                        editMode = .inactive
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete All Conversations?",
            isPresented: $isShowingDeleteAllDialog,
            titleVisibility: .visible
        ) {
            Button("Delete All Conversations", role: .destructive) {
                selectedIDs.removeAll()
                Task {
                    await env.deleteAll()
                    editMode = .inactive
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all \(env.conversations.count) conversation\(env.conversations.count == 1 ? "" : "s") and cannot be undone.")
        }
        .onChange(of: env.conversations) { _, newConversations in
            let validIDs = Set(newConversations.map(\.id))
            selectedIDs.formIntersection(validIDs)
            if newConversations.isEmpty && editMode.isEditing {
                editMode = .inactive
                selectedIDs.removeAll()
            }
        }
        .onChange(of: editMode) { _, newMode in
            if !newMode.isEditing {
                selectedIDs.removeAll()
            } else {
                renamingID = nil
            }
        }
        .onChange(of: isRenameFocused) { _, focused in
            if !focused, let id = renamingID {
                commitRename(for: id)
            }
        }
    }

    // MARK: Rows

    private func row(for summary: ConversationSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.title.isEmpty ? "New Conversation" : summary.title)
                .font(.appSans(.body))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(summary.model)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("·")
                Text(summary.updatedAt, format: .relative(presentation: .named))
            }
            .font(.appSans(.caption))
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
            systemImage: "arrow.uturn.backward.circle"
        )
        .font(.appSans(.footnote))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var emptyState: some View {
        if env.hasToken {
            ContentUnavailableView {
                Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Start one with the compose button.")
                    .font(.appSans(.subheadline))
                    .appLineSpacing(.subheadline)
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
                .font(.appSans(.subheadline))
                .appLineSpacing(.subheadline)
            } actions: {
                Button("Open Settings") { path.append(.settings) }
                    .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Actions

    private func commitRename(for id: UUID) {
        let title = renameText
        renamingID = nil
        Task {
            await env.rename(id, to: title)
        }
    }

    private func createConversation() {
        guard !isCreating else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            if let id = await env.newConversation() {
                path.append(.conversation(id))
            }
        }
    }
}
