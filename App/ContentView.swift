import SwiftUI

struct ContentView: View {
    @State private var verificationCount = 0
    @StateObject private var connectionTester = CameraConnectionTester()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Phase 0 verified on device", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text("Phase 1 adds a TCP-only probe. It does not start video or parse JPEG frames yet.")
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

                Section("Phase 1 · Local TCP") {
                    Text("First join the camera Wi-Fi in iOS Settings, then return here. The first test may show the Local Network permission prompt.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LabeledContent("Target", value: "192.168.169.1:6123")
                    LabeledContent("Result", value: connectionTester.phase.title)

                    if let detail = connectionTester.phase.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Button {
                        connectionTester.testConnection()
                    } label: {
                        if connectionTester.isRunning {
                            HStack {
                                ProgressView()
                                Text("Testing…")
                            }
                        } else {
                            Label("Test TCP 6123", systemImage: "network")
                        }
                    }
                    .disabled(connectionTester.isRunning)
                }

                Section("UI check") {
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
