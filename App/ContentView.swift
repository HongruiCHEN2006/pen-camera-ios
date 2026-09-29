import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = PenCameraStream()
    @StateObject private var connectionTester = CameraConnectionTester()
    @StateObject private var analysis = ExamAnalysisController()
    @State private var showsAnalysisSettings = false
    @State private var showsAnalysisResult = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    preview
                    streamControls
                    analysisStatus
                    streamDetails
                    captureDetails
                    tcpDiagnostic
                    hardwareBaseline
                }
                .padding()
            }
            .navigationTitle("Pen Camera")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsAnalysisSettings = true
                    } label: {
                        Image(systemName: "key.fill")
                    }
                    .accessibilityLabel("OpenAI analysis settings")
                }
            }
            .sheet(isPresented: $showsAnalysisSettings) {
                APISettingsView(controller: analysis)
            }
            .navigationDestination(isPresented: $showsAnalysisResult) {
                AnalysisResultView(controller: analysis)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    analysis.stopContinuous(
                        message: "Continuous analysis stopped because the app moved to the background."
                    )
                    camera.stopStream()
                }
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.black)
                .aspectRatio(4 / 3, contentMode: .fit)

            if let image = camera.latestImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 36))
                    Text("No complete JPEG frame yet")
                        .font(.subheadline)
                }
                .foregroundStyle(.white.opacity(0.72))
            }

            VStack {
                HStack {
                    Label(camera.state.title, systemImage: camera.state.isLive ? "dot.radiowaves.left.and.right" : "circle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.62), in: Capsule())
                        .foregroundStyle(camera.state.isLive ? .green : .white)
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private var streamControls: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    camera.startStream()
                } label: {
                    Label("Start Live", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!camera.canStart)

                Button(role: .destructive) {
                    analysis.stopContinuous(
                        message: "Continuous analysis stopped with the camera stream."
                    )
                    camera.stopStream()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(camera.canStart)
            }

            Button {
                guard let jpeg = camera.latestJPEG else { return }
                guard analysis.hasStoredAPIKey else {
                    showsAnalysisSettings = true
                    return
                }
                camera.captureLatest(jpeg: jpeg)
                analysis.analyze(jpeg: jpeg)
                showsAnalysisResult = true
            } label: {
                Label("CAPTURE & ANALYZE", systemImage: "viewfinder.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(
                camera.latestJPEG == nil
                    || analysis.isAnalyzing
                    || analysis.isContinuousActive
            )

            HStack {
                Button {
                    guard analysis.hasStoredAPIKey else {
                        showsAnalysisSettings = true
                        return
                    }
                    analysis.startContinuous { [weak camera] in
                        camera?.latestJPEG
                    }
                } label: {
                    Label("Start 3s Analysis", systemImage: "bell.badge.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(
                    camera.latestJPEG == nil
                        || analysis.isAnalyzing
                        || analysis.isContinuousActive
                )

                Button(role: .destructive) {
                    analysis.stopContinuous()
                } label: {
                    Label("Stop Analysis", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!analysis.isContinuousActive)
            }

            Button {
                camera.captureLatest()
            } label: {
                Label("Save Frame Only", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(camera.latestJPEG == nil)
        }
    }

    private var analysisStatus: some View {
        GroupBox("OpenAI question reader") {
            VStack(spacing: 10) {
                valueRow("API Key", analysis.hasStoredAPIKey ? "Stored in Keychain" : "Not configured")
                valueRow("Model", analysis.model)
                valueRow("Camera route", camera.routeStatus)
                valueRow("Cloud route", analysis.cloudRoute.title)
                valueRow("Continuous", analysis.continuousState.title)
                valueRow("API request", analysis.continuousRequestInFlight ? "In progress" : "Idle")
                valueRow("Requests", "\(analysis.continuousRequestCount)")
                valueRow("iOS notifications", "\(analysis.notificationCount)")
                valueRow("Remembered questions", "\(analysis.historyCount)")
                if let detail = analysis.cloudRoute.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if let detail = analysis.continuousState.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if let message = analysis.lastContinuousMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Text("Continuous mode analyzes the newest frame at most once every 3 seconds. Every new complete question creates a real iOS local notification with its question number and answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Clear analyzed-question history", role: .destructive) {
                    analysis.clearQuestionHistory()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(analysis.isContinuousActive || analysis.historyCount == 0)

                if !analysis.hasStoredAPIKey {
                    Button("Configure API Key") {
                        showsAnalysisSettings = true
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
        }
    }

    private var streamDetails: some View {
        GroupBox("Live stream") {
            VStack(spacing: 10) {
                valueRow("Endpoint", "192.168.169.1:6123")
                valueRow("State", camera.state.title)
                valueRow("Complete frames", "\(camera.frameCount)")
                valueRow("Dropped / invalid", "\(camera.invalidJPEGCount)")
                if let firmware = camera.firmware {
                    valueRow("Reported firmware", firmware)
                }
                if let date = camera.lastFrameAt {
                    valueRow("Latest frame", date.formatted(date: .omitted, time: .standard))
                }
                if let detail = camera.state.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var captureDetails: some View {
        if camera.captureMessage != nil || camera.lastCaptureName != nil {
            GroupBox("Latest capture") {
                VStack(alignment: .leading, spacing: 6) {
                    if let filename = camera.lastCaptureName {
                        Text(filename)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    }
                    if let message = camera.captureMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
    }

    private var tcpDiagnostic: some View {
        GroupBox("TCP diagnostic") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Use this only when the full live-stream handshake fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                valueRow("Result", connectionTester.phase.title)
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
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Test TCP 6123", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(connectionTester.isRunning || !camera.canStart)
            }
            .padding(.top, 6)
        }
    }

    private var hardwareBaseline: some View {
        GroupBox("D7WN AP baseline") {
            VStack(spacing: 10) {
                valueRow("SSID", "Nax_5cf097da7367")
                valueRow("Camera", "192.168.169.1:6123")
                valueRow("MAC", "5c:f0:97:da:73:67")
                valueRow("Firmware", "202607151817")
            }
            .padding(.top, 6)
        }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

#Preview {
    ContentView()
}
