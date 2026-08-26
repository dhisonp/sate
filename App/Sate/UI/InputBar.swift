import SwiftUI

/// Composer + Search Toggle + Send/Stop (R4.1).
///
/// Send/Stop state deliberately lives here rather than in `ChatView`: this view's
/// body is the only place that reads `vm.phase` for the button, so a phase change
/// re-evaluates a three-control `HStack` instead of the whole transcript.
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

    /// The field and the action buttons are adjacent glass elements sharing
    /// `ChatView`'s `GlassEffectContainer` for consistent sampling.
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $vm.input, axis: .vertical)
                .lineLimit(1 ... 6)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.return)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .glassEffect(.regular, in: .capsule)
                .accessibilityLabel("Message")

            searchButton

            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var searchButton: some View {
        Button {
            vm.isSearchEnabled.toggle()
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: vm.isSearchEnabled ? .bold : .medium))
                .foregroundStyle(vm.isSearchEnabled ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .clipShape(Circle())
        .frame(minWidth: 44, minHeight: 44)
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
