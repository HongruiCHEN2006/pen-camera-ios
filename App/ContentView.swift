import SwiftUI

struct ContentView: View {
    @State private var verificationCount = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Phase 0 build installed", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text("This build only verifies the unsigned IPA delivery path. Camera access comes next.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Target device") {
                    LabeledContent("Model", value: "iPhone 16 Pro")
                    LabeledContent("iOS", value: "26.6.1")
                }

                Section("D7WN AP baseline") {
                    LabeledContent("SSID", value: "Nax_5cf097da7367")
                    LabeledContent("Endpoint", value: "192.168.169.1:6123")
                    LabeledContent("MAC", value: "5c:f0:97:da:73:67")
                    LabeledContent("Firmware", value: "202607151817")
                }

                Section("Installation check") {
                    Button("Test button") {
                        verificationCount += 1
                    }
                    LabeledContent("Button taps", value: "\(verificationCount)")
                }
            }
            .navigationTitle("Pen Camera")
        }
    }
}

#Preview {
    ContentView()
}

