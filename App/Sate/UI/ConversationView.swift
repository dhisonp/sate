import SwiftUI

/// The transcript screen.
///
/// The single most important property of this view: **its body never reads
/// `draft.text` or any other per-token state.** `@Observable` records the
/// properties a body actually touched and invalidates that body when they change,
/// so one read of `draft.text` here would re-evaluate the whole `LazyVStack` at
/// the flush cadence. Everything token-rate lives in `StreamingMessageView` and
/// `ThinkingIndicator`; Send/Stop lives in `InputBar`.
struct ConversationView: View {
    let vm: ConversationViewModel

    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bottom sentinel for the "re-pin" button. Constant, so no state churn.
    private let bottomAnchor = "sate.transcript.bottom"

    /// Pinned = the transcript follows new content. Unset only by a real user
    /// drag (see `onScrollPhaseChange`).
    @State private var isPinned = true
    @State private var isAtBottom = true
    @State private var isUserDriven = false

    @State private var editing: Message?
    @State private var editText = ""
    @State private var isEditingModel = false
    @State private var completionTrigger = 0
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        transcript
            // The composer and the status pill are the navigation layer: they
            // float above the transcript on Liquid Glass rather than sitting on
            // an opaque bar. One `GlassEffectContainer` for the whole inset —
            // glass cannot sample other glass, so adjacent elements (the field,
            // the send button, the pill, the debug panel) need a shared
            // sampling region.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 8) {
                        statusArea
                        if env.settings.showDebugPanel, let trace = vm.lastTrace {
                            DebugPanel(trace: trace)
                                .padding(.horizontal, 16)
                        }
                        InputBar(vm: vm)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle(vm.isRenaming ? "" : vm.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task(id: vm.conversationID) { await vm.load() }
            .onChange(of: vm.phase) { _, phase in announce(phase) }
            .onChange(of: vm.isRenaming) { _, isRenaming in
                if isRenaming {
                    isRenameFocused = true
                }
            }
            .onChange(of: isRenameFocused) { _, isFocused in
                if !isFocused && vm.isRenaming {
                    vm.cancelRename()
                }
            }
            // A success haptic on clean completion (R3.6); the counter only ever
            // increments on a terminal phase, so it never fires mid-stream.
            .sensoryFeedback(.success, trigger: completionTrigger)
            .sheet(item: $editing) { message in
                EditMessageSheet(original: message, text: $editText) { newText in
                    Task { await vm.edit(message.id, newText: newText) }
                }
            }
            .sheet(isPresented: $isEditingModel) {
                ModelSheet(vm: vm)
            }
            .onDisappear {
                // Rendered blocks are per-message and worth nothing once the
                // conversation is closed (R2.6). The generation itself keeps
                // running — it is owned by the store, not by this view.
                MarkdownCache.clear()
                env.evictIdleViewModel(for: vm.conversationID)
            }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // A `List` is forbidden here: UICollectionView self-sizing
                    // re-measures a mutating row on every change and the
                    // transcript visibly jumps while tokens land.
                    ForEach(vm.visibleMessages) { message in
                        TurnView(
                            message: message,
                            siblings: vm.siblings(of: message.id),
                            showThinking: env.settings.showThinking,
                            onEdit: beginEditing,
                            onSwitchBranch: { id in Task { await vm.switchBranch(to: id) } }
                        )
                        .equatable()
                        .id(message.id)
                        .transition(reduceMotion ? .identity : .opacity)
                    }

                    // Always present, so committing the draft into the transcript
                    // is not a view-type change and does not move the scroll.
                    StreamingMessageView(
                        draft: vm.draft,
                        isThinking: vm.thinkingLevel != .off,
                        showThinking: env.settings.showThinking
                    )
                    .transition(reduceMotion ? .identity : .opacity)

                    generationFooter

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: vm.visibleMessages.count)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // `visibleRect` rather than the raw offset: the offset misreads
            // keyboard inset changes and reports "not at bottom" spuriously.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                isAtBottom = atBottom
                if isUserDriven {
                    if !atBottom {
                        isPinned = false
                    }
                } else if atBottom {
                    isPinned = true
                }
            }
            // Follow new output smoothly without lag or rubber-banding when pinned.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, _ in
                if isPinned && !isUserDriven {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            // Geometry callbacks also fire for programmatic scrolls, so "the user
            // scrolled away" is only believed while an actual gesture is driving.
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .interacting, .decelerating:
                    isUserDriven = true
                    if !isAtBottom {
                        isPinned = false
                    }
                default:
                    isUserDriven = false
                    if isAtBottom {
                        isPinned = true
                    }
                }
            }
            .onChange(of: vm.phase) { oldPhase, newPhase in
                let wasBusy = oldPhase == .streaming || oldPhase == .awaitingFirstToken || oldPhase.isBusy
                if isPinned, !isUserDriven, wasBusy, !newPhase.isBusy {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                if !isPinned {
                    NewTokensChip {
                        isPinned = true
                        // No animation on token updates; this one is a discrete
                        // user action, and Reduce Motion still suppresses it.
                        if reduceMotion {
                            proxy.scrollTo(bottomAnchor, anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomAnchor, anchor: .bottom)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: Footer

    /// Model, tokens in/out, TTFB and duration for the turn that just finished.
    /// Token counts come from the message's own `usage` (the gateway's final
    /// `stream_options` chunk); timings come from the trace.
    @ViewBuilder
    private var generationFooter: some View {
        if !vm.phase.isBusy,
           let trace = vm.lastTrace,
           let last = vm.messages.last,
           last.role == .assistant
        {
            VStack(alignment: .leading, spacing: 3) {
                Text(footerLine(trace: trace, usage: last.usage))
                    .font(.appSans(.caption2))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if (trace.step ?? 0) > 0 {
                    Label("served by fallback", systemImage: "arrow.triangle.branch")
                        .font(.appSans(.caption2))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func footerLine(trace: NetworkTrace, usage: Usage?) -> String {
        var parts: [String] = []
        let model = trace.model.isEmpty ? vm.model : trace.model
        if !model.isEmpty {
            parts.append(model)
        }
        if let usage {
            parts.append("\(usage.promptTokens) in / \(usage.completionTokens) out")
        }
        if let ttfb = trace.timeToFirstByte {
            parts.append("TTFB \(Int((ttfb * 1000).rounded())) ms")
        }
        if let duration = trace.duration {
            parts.append(String(format: "%.1fs", duration))
        }
        if trace.cacheStatus == "HIT" {
            parts.append("cached")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Status area

    /// Everything between the transcript and the composer. Reads `phase`, which
    /// changes a handful of times per response — never per token.
    @ViewBuilder
    private var statusArea: some View {
        switch vm.phase {
        case .sending:
            statusRow {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sending…").font(.appSans(.footnote)).foregroundStyle(.secondary)
                }
                .statusPillGlass()
            }

        case let .searching(query):
            statusRow {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching “\(query)”…")
                        .font(.appSans(.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .statusPillGlass()
            }

        case .awaitingFirstToken:
            statusRow { ThinkingIndicator(draft: vm.draft, isThinking: vm.thinkingLevel != .off).statusPillGlass() }

        case let .failed(error):
            statusRow {
                ErrorBanner(error: error, onRetry: { Task { await vm.retry() } })
            }

        case .interrupted:
            statusRow { recoveryRow(title: "Response interrupted.") }

        case .idle, .streaming:
            if vm.canContinue {
                statusRow { recoveryRow(title: "The response is incomplete.") }
            }
        }
    }

    private func statusRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }

    private func recoveryRow(title: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.appSans(.footnote))
                .appLineSpacing(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if vm.canContinue {
                Button("Continue") { Task { await vm.continueGeneration() } }
                    .font(.appSans(.footnote, weight: .semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            Button("Regenerate") { Task { await vm.regenerate() } }
                .font(.appSans(.footnote, weight: .semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if vm.isRenaming {
            @Bindable var vm = vm
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    vm.cancelRename()
                }
            }
            ToolbarItem(placement: .principal) {
                TextField("Title", text: $vm.renameDraft)
                    .font(.appSans(.headline))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($isRenameFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        Task { await vm.commitRename() }
                    }
                    .onKeyPress(.escape) {
                        vm.cancelRename()
                        return .handled
                    }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    Task { await vm.commitRename() }
                }
                .fontWeight(.semibold)
                .disabled(vm.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else {
            ToolbarItem(placement: .principal) {
                Button {
                    guard !vm.phase.isBusy else { return }
                    vm.beginRename()
                    isRenameFocused = true
                } label: {
                    Text(vm.title)
                        .font(.appSans(.headline))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(vm.phase.isBusy)
                .accessibilityLabel("Conversation title: \(vm.title)")
                .accessibilityHint(vm.phase.isBusy ? "" : "Double-tap to rename conversation")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEditingModel = true
                } label: {
                    Label(vm.model, systemImage: "cpu")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Model: \(vm.model)")
            }
        }
    }

    // MARK: Actions

    private func beginEditing(_ message: Message) {
        editText = message.text
        editing = message
    }

    /// VoiceOver gets one announcement per terminal phase instead of a re-read on
    /// every flush (the streaming text is hidden from the accessibility tree).
    private func announce(_ phase: ConversationPhase) {
        switch phase {
        case .idle:
            completionTrigger &+= 1
            AccessibilityNotification.Announcement("Response complete").post()
        case .interrupted:
            AccessibilityNotification.Announcement("Response interrupted").post()
        case let .failed(error):
            AccessibilityNotification.Announcement(error.userMessage).post()
        case .sending, .searching, .awaitingFirstToken, .streaming:
            break
        }
    }
}

// MARK: - Chip

/// Shown when the user has scrolled away from the bottom while output continues.
/// A floating navigation-layer control, so it gets glass; the transcript it
/// floats over does not.
private struct NewTokensChip: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label("New tokens", systemImage: "arrow.down")
                .font(.appSans(.footnote, weight: .semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .frame(minHeight: 44)
        .accessibilityLabel("Scroll to newest output")
    }
}

// MARK: - Glass helpers

private extension View {
    /// The status pill ("Sending…", "Thinking… (Ns)"): hugs its content and sits
    /// on regular glass. `.clear` is wrong here — the pill floats over plain
    /// text, not media.
    func statusPillGlass() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Error banner

private struct ErrorBanner: View {
    let error: GatewayError
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(error.userMessage)
                    .font(.appSans(.footnote))
                    .appLineSpacing(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry", action: onRetry)
                    .font(.appSans(.footnote, weight: .semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(14)
        // The one place a tint is earned outside the send button: it carries the
        // failure state, it is not decoration.
        .glassEffect(.regular.tint(.orange.opacity(0.28)), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Sheets

/// Edit-and-resend. The result is a *sibling* of the original, never an
/// overwrite, so the previous branch stays reachable via "‹ 2/3 ›".
private struct EditMessageSheet: View {
    let original: Message
    @Binding var text: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GlassEffectContainer {
                TextEditor(text: $text)
                    .font(.appSans(.body))
                    .appLineSpacing(.body)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .padding(16)
            }
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resend") {
                        onSubmit(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Model strings are free-form — the gateway resolves them, including dynamic
/// routes like `dynamic/assistant` — so this is a text field, not a picker.
private struct ModelSheet: View {
    @Bindable var vm: ConversationViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("provider/model", text: $vm.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Model for this conversation")
                        .settingsSectionHeader()
                } footer: {
                    Text("Free-form. The gateway resolves it, including dynamic routes.")
                        .settingsSectionFooter()
                }

                if !env.settings.defaultModel.isEmpty, env.settings.defaultModel != vm.model {
                    Section {
                        Button("Use default: \(env.settings.defaultModel)") {
                            vm.model = env.settings.defaultModel
                        }
                    }
                }

                Section {
                    Picker("Thinking", selection: $vm.thinkingLevel) {
                        ForEach(ThinkingLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                } header: {
                    Text("Reasoning")
                        .settingsSectionHeader()
                } footer: {
                    Text("Thinking level controls reasoning effort before answering.")
                        .settingsSectionFooter()
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
