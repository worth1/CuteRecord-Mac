import SwiftUI

struct AIScriptComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var interfaceLanguage = InterfaceLanguageSettings.shared

    let sourceTitle: String
    let sourceMarkdown: String
    let onSubmit: (AIBreathCutSubmission) -> Void

    @State private var breathMarkerMode: AIBreathMarkerMode = .marked
    @State private var customPrompt = ""
    @State private var apiKey = ""
    @State private var isEditingAPIKey = false
    @State private var shouldSaveAPIKey = true
    @State private var errorMessage: String?
    @State private var showAdvanced = false

    // Advanced — custom provider/model
    @State private var customBaseURL = AIScriptModelSelectionStorage.customBaseURL()
    @State private var customModelID = AIScriptModelSelectionStorage.customModelID()

    private let keyStore = AIProviderAPIKeyStore.shared

    // Default: DeepSeek (free tier, great Chinese support)
    private let defaultProvider = AIScriptProviderCatalog.provider(for: "deepseek")
    private let defaultModelID = "deepseek-v4-flash"
    private let defaultEndpoint = AIChatEndpoint.chatCompletionsURL(from: "https://api.deepseek.com")!

    private var usesCustomProvider: Bool {
        !customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activeKeychainAccount: String {
        guard usesCustomProvider else { return defaultProvider.id }
        let normalized = customBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(AIScriptProviderCatalog.customProviderID):\(normalized)"
    }

    private var hasSavedAPIKey: Bool {
        keyStore.hasAPIKey(for: activeKeychainAccount)
    }

    private var requiresAPIKeyInput: Bool {
        !hasSavedAPIKey || isEditingAPIKey
    }

    private var resolvedModelID: String {
        usesCustomProvider
            ? (customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? defaultModelID
                : customModelID.trimmingCharacters(in: .whitespacesAndNewlines))
            : defaultModelID
    }

    private var resolvedEndpoint: URL {
        if usesCustomProvider {
            return AIChatEndpoint.chatCompletionsURL(from: customBaseURL) ?? defaultEndpoint
        }
        return defaultEndpoint
    }

    private var canGenerate: Bool {
        !sourceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresAPIKeyInput || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func t(_ english: String) -> String {
        interfaceLanguage.text(english)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(t("AI Breath Cuts"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(sourceTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Output mode picker
                Picker(t("Breath Marks"), selection: $breathMarkerMode) {
                    ForEach(AIBreathMarkerMode.allCases) { mode in
                        Text(mode.localizedLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            // Body
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // API Key
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("API Key")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if hasSavedAPIKey {
                                Button(isEditingAPIKey ? t("Use Saved Key") : t("Replace Key")) {
                                    isEditingAPIKey.toggle()
                                    if !isEditingAPIKey { apiKey = "" }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                            }
                        }

                        if requiresAPIKeyInput {
                            SecureField("sk-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))

                            Toggle(t("Save key in Keychain"), isOn: $shouldSaveAPIKey)
                                .font(.system(size: 11))
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                                Text(t("Saved key in Keychain"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }

                        if requiresAPIKeyInput {
                            Text("\(t("Get a free API key at")) api.deepseek.com")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Custom prompt
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t("Notes"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $customPrompt)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 72)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                if customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(t("Optional instructions, e.g. shorter lines, preserve paragraph shape, or cut more aggressively."))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 12)
                                        .allowsHitTesting(false)
                                }
                            }
                    }

                    // Advanced
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(t("Base URL (optional)"), text: $customBaseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))

                            TextField(t("Model ID"), text: $customModelID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                        }
                        .padding(.top, 4)
                    } label: {
                        Text(t("Advanced"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    // Error
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Button(t("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    submit()
                } label: {
                    Label(t("Create Draft"), systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canGenerate)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420, height: 400)
        .background(.ultraThinMaterial)
        .onAppear {
            if hasSavedAPIKey {
                isEditingAPIKey = false
                apiKey = ""
            } else {
                isEditingAPIKey = true
            }
        }
        .onChange(of: customBaseURL) { _, _ in
            refreshAPIKeyState()
        }
    }

    @MainActor
    private func submit() {
        guard canGenerate else { return }
        errorMessage = nil

        let modelConfiguration: AIChatModelConfiguration
        let resolvedAPIKey: String?

        // Determine provider display name
        let providerName: String
        let providerID: String
        if usesCustomProvider {
            providerName = "Custom"
            providerID = AIScriptProviderCatalog.customProviderID
        } else {
            providerName = defaultProvider.displayName
            providerID = defaultProvider.id
        }

        modelConfiguration = AIChatModelConfiguration(
            providerID: providerID,
            providerDisplayName: providerName,
            modelID: resolvedModelID,
            modelDisplayName: resolvedModelID,
            endpoint: resolvedEndpoint,
            apiKeyLabel: "API Key",
            requiresAPIKey: true,
            keychainAccount: activeKeychainAccount
        )

        // Resolve API key
        if requiresAPIKeyInput {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                errorMessage = t("Enter an API key.")
                return
            }
            if shouldSaveAPIKey {
                do {
                    try keyStore.saveAPIKey(trimmed, for: activeKeychainAccount)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
            resolvedAPIKey = trimmed
        } else if let saved = keyStore.loadAPIKey(for: activeKeychainAccount) {
            resolvedAPIKey = saved
        } else {
            isEditingAPIKey = true
            errorMessage = t("Enter an API key.")
            return
        }

        // Save advanced settings
        AIScriptModelSelectionStorage.save(
            providerID: providerID,
            modelID: resolvedModelID,
            customProviderName: "",
            customBaseURL: customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            customModelID: customModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            customProviderRequiresAPIKey: true
        )

        let request = AIBreathCutRequest(
            sourceMarkdown: sourceMarkdown,
            customPrompt: customPrompt,
            model: modelConfiguration,
            markerMode: breathMarkerMode
        )

        let trimmedSourceTitle = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedSourceTitle.isEmpty ? t("Untitled") : trimmedSourceTitle
        let generatedTitle = "\(t("AI Breath Cuts")) - \(base)"

        onSubmit(AIBreathCutSubmission(
            request: request,
            apiKey: resolvedAPIKey,
            generatedTitle: generatedTitle
        ))
        dismiss()
    }

    private func refreshAPIKeyState() {
        apiKey = ""
        shouldSaveAPIKey = true
        isEditingAPIKey = !hasSavedAPIKey
    }
}
