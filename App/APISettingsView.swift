import SwiftUI

struct APISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: ExamAnalysisController

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI API Key") {
                    SecureField(
                        controller.hasStoredAPIKey ? "Saved key (leave blank to keep it)" : "Paste API Key",
                        text: $controller.apiKeyDraft
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()

                    Label(
                        controller.hasStoredAPIKey ? "A key is stored on this iPhone" : "No key is stored",
                        systemImage: controller.hasStoredAPIKey ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(controller.hasStoredAPIKey ? .green : .orange)

                    Text("The key is stored in iOS Keychain with this-device-only protection. It is never written to source code, Git, capture files, or app logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Model") {
                    TextField("Model", text: $controller.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Default: gpt-4o-mini. You can change this if your OpenAI project uses a different vision-capable model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Network experiment") {
                    Text("The camera remains on local Wi-Fi. The OpenAI request allows cellular data and waits for an internet route. Whether iOS actually uses cellular while joined to the D7WN AP is verified only by a successful physical request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = controller.settingsMessage {
                    Section("Status") {
                        Text(message)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                if controller.hasStoredAPIKey {
                    Section {
                        Button("Remove API Key", role: .destructive) {
                            controller.removeAPIKey()
                        }
                    }
                }
            }
            .navigationTitle("Analysis Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if controller.saveSettings() {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
