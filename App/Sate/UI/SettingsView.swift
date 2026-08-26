import SwiftUI

/// Everything the user can configure.
///
/// The API token is **write-only** here: it lives in the Keychain and is never
/// read back into the UI. The field shows whether one is stored, never its value.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var tokenEntry = ""
    @State private var hasStoredToken = false
    @State private var isTemperatureEnabled = false

    var body: some View {
        @Bindable var env = env

        Form {
            Section {
                LabeledContent("Account ID") {
                    TextField("32-character hex", text: $env.settings.accountID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Gateway ID") {
                    TextField("gateway name", text: $env.settings.gatewayID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Cloudflare")
            } footer: {
                Text("Both appear on the AI Gateway page of the Cloudflare dashboard.")
            }

            Section {
                // SecureField bound to a scratch string: the stored token is
                // never fetched for display, only replaced or cleared.
                SecureField(hasStoredToken ? "•••• set — enter to replace" : "API token", text: $tokenEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save Token") {
                    env.setToken(tokenEntry)
                    tokenEntry = ""
                    hasStoredToken = env.token() != nil
                }
                .disabled(tokenEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredToken {
                    Button("Remove Token", role: .destructive) {
                        env.setToken(nil)
                        tokenEntry = ""
                        hasStoredToken = false
                    }
                }
            } header: {
                Text("API Token")
            } footer: {
                Text("""
                The token needs BOTH permissions: Account › Workers AI › Read \
                (REST endpoints) and AI Gateway › Run (compat and dynamic routes). \
                A token with only one of them fails with 401 or 403.

                It is stored in the Keychain, only unlocked on this device, and is \
                never written to logs or the debug panel. Restoring to a new device \
                requires entering it again.
                """)
            }

            Section {
                LabeledContent("Default model") {
                    TextField("provider/model", text: $env.settings.defaultModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Title model") {
                    TextField("provider/model", text: $env.settings.titleModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Free-form strings resolved by the gateway. The title model is used only for auto-naming conversations.")
            }

            Section {
                TextField(
                    "Optional instructions sent with every turn",
                    text: $env.settings.systemPrompt,
                    axis: .vertical)
                    .lineLimit(3...12)

                if env.settings.systemPrompt != SystemPrompt.researchAssistant {
                    Button("Restore Default Prompt") {
                        env.settings.systemPrompt = SystemPrompt.researchAssistant
                    }
                }
            } header: {
                Text("System Prompt")
            } footer: {
                Text("\(SystemPrompt.currentDateToken) is replaced with today's date on every send. Sate has no web access, so the default prompt tells the model to say what it last knew and when, rather than presenting stale facts as current.")
            }

            Section {
                LabeledContent("Max tokens") {
                    TextField("4096", value: $env.settings.maxTokens, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }

                Toggle("Set temperature", isOn: $isTemperatureEnabled)
                if isTemperatureEnabled {
                    let temperature = Binding<Double>(
                        get: { env.settings.temperature ?? 0.7 },
                        set: { env.settings.temperature = $0 })
                    VStack(alignment: .leading) {
                        Text(String(format: "Temperature %.2f", temperature.wrappedValue))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Slider(value: temperature, in: 0...2, step: 0.05)
                            .accessibilityLabel("Temperature")
                    }
                }
            } header: {
                Text("Generation")
            } footer: {
                Text("Max tokens is always sent — several providers default to a small or unbounded value. Leaving temperature unset omits the field so the provider default applies, which is not the same as sending 0.")
            }

            Section {
                Toggle("Report token usage", isOn: $env.settings.includeUsage)
                Toggle("Keep payloads in gateway log", isOn: $env.settings.collectLogPayload)
                Toggle("Show debug panel", isOn: $env.settings.showDebugPanel)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Usage reporting requests stream_options.include_usage — without it there are no prompt-token counts to calibrate context estimates from. Turning off payload logging keeps prompts and responses out of the Cloudflare log viewer.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hasStoredToken = env.token() != nil
            isTemperatureEnabled = env.settings.temperature != nil
        }
        .onChange(of: isTemperatureEnabled) { _, enabled in
            if !enabled {
                env.settings.temperature = nil
            } else if env.settings.temperature == nil {
                env.settings.temperature = 0.7
            }
        }
    }
}
