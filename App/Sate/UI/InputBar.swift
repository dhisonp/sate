import SwiftUI

/// Composer + Expandable Config Bubble + Send/Stop (R4.1).
///
/// Send/Stop state deliberately lives here rather than in `ChatView`: this view's
/// body is the only place that reads `vm.phase` for the button, so a phase change
/// re-evaluates this control instead of the whole transcript.
///
/// The field is always interactive — the user can keep typing the next prompt
/// while a response streams, and the text survives a failed send because the
/// draft lives in the view model, not in local `@State`.
struct InputBar: View {
    @Bindable var vm: ChatViewModel
    @FocusState private var isFocused: Bool

    private var isBusy: Bool {
        vm.phase.isBusy
    }

    private var canSend: Bool {
        !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Message", text: $vm.input, axis: .vertical)
                .font(.appSans(.body))
                .lineLimit(1 ... 8)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.return)
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .accessibilityLabel("Message")

            HStack(alignment: .center, spacing: 8) {
                thinkingButton
                searchButton

                Spacer(minLength: 0)

                actionButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var thinkingButton: some View {
        Menu {
            Picker("Thinking", selection: $vm.thinkingLevel) {
                ForEach(ThinkingLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: vm.thinkingLevel == .off ? "brain" : "brain.fill")
                    .font(.system(size: 14, weight: vm.thinkingLevel == .off ? .medium : .bold))
                Text(vm.thinkingLevel.displayName)
                    .font(.appSans(.footnote, weight: .medium))
            }
            .foregroundStyle(vm.thinkingLevel == .off ? Color.secondary : Color.accentColor)
            .frame(minHeight: 36)
            .padding(.horizontal, 10)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel("Thinking: \(vm.thinkingLevel.displayName)")
        .accessibilityHint("Select thinking effort for this conversation")
    }

    private var searchButton: some View {
        Button {
            vm.isSearchEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: vm.isSearchEnabled ? .bold : .medium))
                Text("Search")
                    .font(.appSans(.footnote, weight: .medium))
            }
            .foregroundStyle(vm.isSearchEnabled ? Color.accentColor : Color.secondary)
            .frame(minHeight: 36)
            .padding(.horizontal, 10)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(vm.isSearchEnabled ? "Web search enabled" : "Web search disabled")
        .accessibilityHint("Double-tap to toggle web search for this conversation")
    }

    private var actionButton: some View {
        Group {
            if isBusy {
                Button {
                    vm.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 17, weight: .semibold))
                }
                // Stop is a secondary affordance: plain glass, no tint.
                .buttonStyle(.glass)
                .accessibilityLabel("Stop response")
            } else {
                Button {
                    isFocused = false
                    Task { await vm.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                }
                // The primary action, and the only tinted control in the app —
                // `.glassProminent` picks up the accent colour itself.
                .buttonStyle(.glassProminent)
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
        // Known iOS 26 artifact: a prominent glass button with a circular border
        // shape renders a square corner without an explicit clip.
        .clipShape(Circle())
        // R3.5: the Send/Stop target stays ≥ 44 pt at the smallest Dynamic Type.
        .frame(minWidth: 44, minHeight: 44)
    }
}
