import SwiftUI

/// Composer + Send/Stop.
///
/// Send/Stop state deliberately lives here rather than in `ChatView`: this view's
/// body is the only place that reads `vm.phase` for the button, so a phase change
/// re-evaluates a two-control `HStack` instead of the whole transcript.
///
/// The field is always interactive — the user can keep typing the next prompt
/// while a response streams, and the text survives a failed send because the
/// draft lives in the view model, not in local `@State`.
struct InputBar: View {
    @Bindable var vm: ChatViewModel
    @FocusState private var isFocused: Bool

    private var isBusy: Bool { vm.phase.isBusy }

    private var canSend: Bool {
        !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The field and the action button are two adjacent glass elements. They are
    /// deliberately *not* wrapped in their own `GlassEffectContainer` here —
    /// `ChatView` puts one around the whole bottom inset so the composer, the
    /// status pill and the debug panel all share a single sampling region.
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $vm.input, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.return)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .glassEffect(.regular, in: .capsule)
                .accessibilityLabel("Message")

            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
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
