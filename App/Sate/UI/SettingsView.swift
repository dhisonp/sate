import OSLog
import SwiftUI

/// Everything the user can configure.
///
/// API tokens are **write-only** here: they live in the Keychain and are never
/// read back into the UI. The fields show whether a token is stored, never its value.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var tokenEntry = ""
    @State private var hasStoredToken = false
    @State private var tokenError: String?
    @State private var searchTokenEntry = ""
    @State private var hasStoredSearchToken = false
    @State private var searchTokenError: String?
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
                LabeledContent("Status") {
                    if hasStoredToken {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Saved in Keychain")
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                            Text("Not configured")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let tokenError {
                    Text(tokenError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // SecureField bound to a scratch string: the stored token is
                // never fetched for display, only replaced or cleared.
                SecureField(hasStoredToken ? "•••• set — enter to replace" : "API token", text: $tokenEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save Token") {
                    do {
                        try env.setToken(tokenEntry)
                        tokenEntry = ""
                        hasStoredToken = env.token() != nil
                        tokenError = nil
                        Log.keychain.info("Token successfully saved from SettingsView")
                    } catch {
                        Log.keychain.error("Failed to save token to Keychain: \(error, privacy: .public)")
                        tokenError = "Failed to save token to Keychain: \(error.localizedDescription)"
                    }
                }
                .disabled(tokenEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredToken {
                    Button("Remove Token", role: .destructive) {
                        do {
                            try env.setToken(nil)
                            tokenEntry = ""
                            hasStoredToken = false
                            tokenError = nil
                            Log.keychain.info("Token successfully removed from SettingsView")
                        } catch {
                            Log.keychain.error("Failed to remove token from Keychain: \(error, privacy: .public)")
                            tokenError = "Failed to remove token from Keychain: \(error.localizedDescription)"
                        }
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
                Picker("Provider", selection: $env.settings.searchProvider) {
                    ForEach(SearchProviderType.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                LabeledContent("Status") {
                    if hasStoredSearchToken {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Saved in Keychain")
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                            Text("Not configured")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let searchTokenError {
                    Text(searchTokenError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                SecureField(
                    hasStoredSearchToken ? "•••• set — enter to replace" : "Tavily API Key (tvly-...)",
                    text: $searchTokenEntry
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button("Save Search Key") {
                    do {
                        try env.setSearchToken(searchTokenEntry)
                        searchTokenEntry = ""
                        hasStoredSearchToken = env.searchToken() != nil
                        searchTokenError = nil
                        Log.keychain.info("Search token successfully saved from SettingsView")
                    } catch {
                        Log.keychain.error("Failed to save search key to Keychain: \(error, privacy: .public)")
                        searchTokenError = "Failed to save search key to Keychain: \(error.localizedDescription)"
                    }
                }
                .disabled(searchTokenEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredSearchToken {
                    Button("Remove Search Key", role: .destructive) {
                        do {
                            try env.setSearchToken(nil)
                            searchTokenEntry = ""
                            hasStoredSearchToken = false
                            searchTokenError = nil
                            Log.keychain.info("Search token successfully removed from SettingsView")
                        } catch {
                            Log.keychain.error("Failed to remove search key from Keychain: \(error, privacy: .public)")
                            searchTokenError = "Failed to remove search key from Keychain: \(error.localizedDescription)"
                        }
                    }
                }

                Toggle("Search by default", isOn: $env.settings.searchEnabledByDefault)

                Stepper("Max search rounds: \(env.settings.maxSearchRounds)", value: $env.settings.maxSearchRounds, in: 1 ... 5)

                Stepper("Results per query: \(env.settings.searchResultsPerQuery)", value: $env.settings.searchResultsPerQuery, in: 1 ... 8)
            } header: {
                Text("Web Search")
            } footer: {
                Text("""
                Uses Tavily Search directly from device. The key is stored securely in the Keychain. \
                A search failure will never block chat.
                """)
            }

            Section {
                ModelField(title: "Default model", model: $env.settings.defaultModel)
                ModelField(title: "Title model", model: $env.settings.titleModel)
            } header: {
                Text("Models")
            } footer: {
                Text("""
                The list is Cloudflare's own @cf models: they run on Workers AI, \
                so they need no provider key of yours. Custom takes any provider/model \
                string the gateway resolves. The title model is used only for auto-naming \
                conversations.
                """)
            }

            Section {
                TextField(
                    "Optional instructions sent with every turn",
                    text: $env.settings.systemPrompt,
                    axis: .vertical
                )
                .lineLimit(3 ... 12)

                if env.settings.systemPrompt != SystemPrompt.generalAssistant {
                    Button("Restore Default Prompt") {
                        env.settings.systemPrompt = SystemPrompt.generalAssistant
                    }
                }
            } header: {
                Text("System Prompt")
            } footer: {
                Text("""
                \(SystemPrompt.currentDateToken) is replaced with today's date on every send. \
                The default prompt instructs the model to provide direct, concise answers \
                and state what it last knew when relevant.
                """)
            }

            Section {
                LabeledContent("Max tokens") {
                    TextField("16384", value: $env.settings.maxTokens, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }

                Picker("Thinking", selection: $env.settings.thinkingLevel) {
                    ForEach(ThinkingLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }

                Toggle("Set temperature", isOn: $isTemperatureEnabled)
                if isTemperatureEnabled {
                    let temperature = Binding<Double>(
                        get: { env.settings.temperature ?? 0.7 },
                        set: { env.settings.temperature = $0 }
                    )
                    VStack(alignment: .leading) {
                        Text(String(format: "Temperature %.2f", temperature.wrappedValue))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Slider(value: temperature, in: 0 ... 2, step: 0.05)
                            .accessibilityLabel("Temperature")
                    }
                }
            } header: {
                Text("Generation")
            } footer: {
                Text("""
                Max tokens is always sent — several providers default to a small or \
                unbounded value. Thinking level controls reasoning effort before \
                answering; higher levels spend more tokens and time, while Off \
                omits the parameter. Leaving temperature unset omits the field so the \
                provider default applies, which is not the same as sending 0.
                """)
            }

            Section {
                Toggle("Report token usage", isOn: $env.settings.includeUsage)
                Toggle("Keep payloads in gateway log", isOn: $env.settings.collectLogPayload)
                Toggle("Always search first turn", isOn: $env.settings.alwaysSearchFirstTurn)
                Toggle("Show debug panel", isOn: $env.settings.showDebugPanel)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("""
                Usage reporting requests stream_options.include_usage — without it \
                there are no prompt-token counts to calibrate context estimates from. \
                Turning off payload logging keeps prompts and responses out of the \
                Cloudflare log viewer.
                """)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hasStoredToken = env.token() != nil
            hasStoredSearchToken = env.searchToken() != nil
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

/// A model row that is a picker over `ModelCatalog` with a Custom escape hatch.
///
/// The catalog is a convenience, not a whitelist: the gateway resolves any
/// `provider/model` string, and removing free-form entry would cut off every
/// non-Workers-AI provider. So Custom is a first-class row, and any value that
/// is not in the catalog opens the field already in that mode.
private struct ModelField: View {
    let title: String
    @Binding var model: String

    @State private var isCustom = false

    private static let customTag = "\u{0}custom"

    var body: some View {
        Picker(title, selection: selection) {
            ForEach(ModelCatalog.all) { option in
                Text(option.displayName).tag(option.id)
            }
            Text("Custom…").tag(Self.customTag)
        }
        // Set before the picker is read, so a stored custom string never flashes
        // as the first catalog entry.
        .onAppear { isCustom = !ModelCatalog.contains(model) }

        if isCustom {
            TextField("provider/model", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        } else if let option = ModelCatalog.option(id: model) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.summary)
                Text("\(option.contextTokens.formatted()) token context\(option.reasons ? " · reasoning" : "")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { isCustom ? Self.customTag : model },
            set: { newValue in
                if newValue == Self.customTag {
                    isCustom = true
                } else {
                    isCustom = false
                    model = newValue
                }
            }
        )
    }
}
