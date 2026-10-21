import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = PenCameraStream()
    @StateObject private var connectionTester = CameraConnectionTester()
    @StateObject private var analysis = ExamAnalysisController()
    @ObservedObject private var backgroundCapture = BackgroundCaptureCoordinator.shared
    @State private var showsAnalysisSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    preview
                    detectionPanel
                    analysisProfilePicker
                    streamControls
                    analysisStatus
                    batchResults
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
            .onAppear {
                analysis.onBatchCompleted = { [weak camera, weak analysis] success in
                    guard let camera, let analysis else { return }
                    if backgroundCapture.isInBackground {
                        analysis.stopContinuous(message: "Background batch finished; reopen to start another.")
                        camera.stopStream()
                    }
                    backgroundCapture.finish(success: success)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                backgroundCapture.isInBackground = phase == .background
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

    private var detectionPanel: some View {
        GroupBox("本轮检测结果") {
            VStack(spacing: 12) {
                valueRow("1. 当前是否黑屏？", analysis.isCurrentFrameBlack.map {
                    $0 ? "是" : "否"
                } ?? "待检测")
                valueRow("2. 是否开始上传？", analysis.hasUploadStarted ? "是" : "否")
                valueRow("3. 是否结束上传？", analysis.hasUploadFinished
                    ? "是（\(analysis.uploadOutcome ?? "已完成")）" : "否")
                valueRow("4. 共计准备上传多少张？", "\(analysis.preparedImageCount) 张")
            }
            .padding(.top, 6)
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

            HStack {
                Button {
                    guard analysis.hasStoredAPIKey else {
                        showsAnalysisSettings = true
                        return
                    }
                    analysis.startContinuous { [weak camera] in
                        guard let camera,
                              camera.state.isLive,
                              let jpeg = camera.latestJPEG,
                              let capturedAt = camera.lastFrameAt else { return nil }
                        return CameraSample(
                            jpeg: jpeg,
                            frameNumber: camera.frameCount,
                            capturedAt: capturedAt
                        )
                    }
                    if analysis.isContinuousActive {
                        backgroundCapture.start { [weak camera, weak analysis] in
                            analysis?.stopContinuous(message: "iOS ended the background capture task.")
                            camera?.stopStream()
                        }
                    }
                } label: {
                    Label("Start G2 Analysis", systemImage: "eyeglasses")
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

    private var analysisProfilePicker: some View {
        GroupBox("Question category") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Category", selection: $analysis.analysisProfile) {
                    ForEach(AnalysisProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.menu)
                .disabled(analysis.isAnalyzing || analysis.isContinuousActive)

                Text(analysis.analysisProfile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    private var analysisStatus: some View {
        GroupBox("OpenAI question reader") {
            VStack(spacing: 10) {
                valueRow("API Key", analysis.hasStoredAPIKey ? "Stored in Keychain" : "Not configured")
                valueRow("Model", analysis.model)
                valueRow("Category", analysis.analysisProfile.displayName)
                valueRow("Camera route", camera.routeStatus)
                valueRow("Cloud route", analysis.cloudRoute.title)
                valueRow("Continuous", analysis.continuousState.title)
                valueRow("Background", backgroundCapture.status)
                valueRow("API request", analysis.continuousRequestInFlight ? "In progress" : "Idle")
                valueRow("Batch uploads", "\(analysis.continuousRequestCount)")
                valueRow("Current images", "\(analysis.preparedImageCount)")
                valueRow(
                    "G2 capture mode",
                    analysis.captureMode == .manualCapture ? "Manual 3-photo bursts" : "Black-screen detection"
                )
                valueRow("G2 questions pushed", "\(analysis.glassesPushCount)")
                valueRow("Notification pop-ups", "\(analysis.notificationCount)")
                valueRow("G2 relay", GlassesRelayServer.endpointDescription)
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
                Text("The G2 can select one capture mode: manual preview with 3-photo bursts, or the original black-screen detection flow. Every batch is uploaded in one cellular API request. Results go to both the G2 and the original iOS notification pop-ups. Keep this app in the foreground while capturing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
    private var batchResults: some View {
        if let result = analysis.lastContinuousResult {
            GroupBox("Latest batch answers") {
                VStack(alignment: .leading, spacing: 12) {
                    if result.questions.isEmpty {
                        Text("No confirmed questions in the latest batch.")
                    }
                    ForEach(result.questions) { question in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(question.questionNumber)：\(question.opening)")
                                .font(.headline)
                            Text("答案：\(question.displayAnswer)")
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
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
