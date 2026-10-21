import Combine
import Foundation
import UIKit

@MainActor
final class ExamAnalysisController: ObservableObject {
    enum CloudRoute: Equatable {
        case cellularRequired
        case connecting
        case cellularVerified
        case failed(String)

        var title: String {
            switch self {
            case .cellularRequired: "Cellular required"
            case .connecting: "Connecting via Cellular"
            case .cellularVerified: "Cellular (verified)"
            case .failed: "Cellular unavailable"
            }
        }

        var detail: String? {
            if case let .failed(message) = self { return message }
            return nil
        }
    }

    enum Phase: Equatable {
        case idle
        case analyzing
        case succeeded(ExamAnalysisResult)
        case failed(String)
    }

    enum ContinuousState: Equatable {
        case stopped
        case startingGlassesRelay
        case waitingForImage
        case recording
        case uploading
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .startingGlassesRelay: "Starting Even G2 relay"
            case .waitingForImage: "Waiting for image (3s checks)"
            case .recording: "Recording (1s samples)"
            case .uploading: "Uploading one batch"
            case .failed: "Stopped with error"
            }
        }

        var isActive: Bool {
            switch self {
            case .startingGlassesRelay, .waitingForImage, .recording, .uploading: true
            case .stopped, .failed: false
            }
        }

        var detail: String? {
            if case let .failed(message) = self { return message }
            return nil
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var cloudRoute: CloudRoute = .cellularRequired
    @Published private(set) var continuousState: ContinuousState = .stopped
    @Published private(set) var continuousRequestCount = 0
    @Published private(set) var glassesPushCount = 0
    @Published private(set) var notificationCount = 0
    @Published private(set) var captureMode: GlassesCaptureMode = .blackScreenDetection
    @Published private(set) var continuousRequestInFlight = false
    @Published private(set) var isCurrentFrameBlack: Bool?
    @Published private(set) var hasUploadStarted = false
    @Published private(set) var hasUploadFinished = false
    @Published private(set) var preparedImageCount = 0
    @Published private(set) var uploadOutcome: String?
    @Published private(set) var lastContinuousMessage: String?
    @Published private(set) var lastContinuousResult: ExamAnalysisResult?
    @Published var apiKeyDraft = ""
    @Published var model: String
    @Published var analysisProfile: AnalysisProfile {
        didSet { preferences.set(analysisProfile.rawValue, forKey: Self.profilePreferenceKey) }
    }
    @Published private(set) var settingsMessage: String?

    private static let profilePreferenceKey = "analysis-profile"
    private let keychain = KeychainStore(service: "com.hongrui.pencamera.openai", account: "api-key")
    private let analyzer: OpenAIExamAnalyzer
    private let glassesRelay: GlassesRelayServer
    private let notificationService: QuestionNotificationService
    private let preferences: UserDefaults
    private var capturedJPEG: Data?
    private var analysisTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var manualBurstTask: Task<Void, Never>?
    private var manualFinishRequested = false
    private var continuousSessionID: UUID?
    private var continuousAnalysisProfile: AnalysisProfile?
    private var currentBatch: CameraBatchCapture?
    private var activeFrameProvider: (@MainActor @Sendable () -> CameraSample?)?
    var onBatchCompleted: ((Bool) -> Void)?

    init(
        analyzer: OpenAIExamAnalyzer = OpenAIExamAnalyzer(),
        preferences: UserDefaults = .standard
    ) {
        self.analyzer = analyzer
        self.preferences = preferences
        glassesRelay = .shared
        notificationService = .shared
        model = OpenAIExamAnalyzer.defaultModel
        analysisProfile = AnalysisProfile(
            rawValue: preferences.string(forKey: Self.profilePreferenceKey) ?? ""
        ) ?? .general
        refreshKeyStatus()
        glassesRelay.setControlHandler { [weak self] action in
            Task { @MainActor [weak self] in self?.handleGlassesControl(action) }
        }
    }

    var isAnalyzing: Bool { phase == .analyzing }
    var isContinuousActive: Bool { continuousState.isActive }

    func saveSettings() -> Bool {
        do {
            let cleanKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanKey.isEmpty {
                try keychain.save(cleanKey)
                apiKeyDraft = ""
            } else if !hasStoredAPIKey {
                settingsMessage = "Enter an OpenAI API Key."
                return false
            }
            refreshKeyStatus()
            settingsMessage = "Saved locally. The API Key is stored in iOS Keychain."
            return true
        } catch {
            settingsMessage = error.localizedDescription
            return false
        }
    }

    func removeAPIKey() {
        stopContinuous(message: "Analysis stopped because the API Key was removed.")
        do {
            try keychain.delete()
            apiKeyDraft = ""
            refreshKeyStatus()
            settingsMessage = "API Key removed from iOS Keychain."
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func analyze(jpeg: Data) {
        guard !isContinuousActive else { return }
        analysisTask?.cancel()
        capturedJPEG = jpeg
        capturedImage = UIImage(data: jpeg)
        phase = .analyzing
        let key: String
        do { key = try loadAPIKey() }
        catch { phase = .failed(error.localizedDescription); return }
        let selectedModel = model
        let selectedProfile = analysisProfile
        cloudRoute = .connecting
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await analyzer.analyze(
                    jpeg: jpeg, apiKey: key, model: selectedModel, profile: selectedProfile
                )
                guard !Task.isCancelled else { return }
                cloudRoute = .cellularVerified
                phase = .succeeded(result)
            } catch is CancellationError {
                return
            } catch let error as CellularHTTPError {
                guard !Task.isCancelled else { return }
                cloudRoute = .failed(error.localizedDescription)
                phase = .failed(error.localizedDescription)
            } catch let error as OpenAIExamError {
                guard !Task.isCancelled else { return }
                updateCloudRoute(after: error)
                phase = .failed(error.localizedDescription)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func retry() {
        guard let capturedJPEG else { return }
        analyze(jpeg: capturedJPEG)
    }

    func startContinuous(frameProvider: @escaping @MainActor @Sendable () -> CameraSample?) {
        guard !isContinuousActive, !isAnalyzing else { return }
        guard frameProvider() != nil else {
            continuousState = .failed("No complete camera frame is available yet.")
            return
        }
        do { _ = try loadAPIKey() }
        catch { continuousState = .failed(error.localizedDescription); return }

        let sessionID = UUID()
        continuousSessionID = sessionID
        continuousAnalysisProfile = analysisProfile
        activeFrameProvider = frameProvider
        continuousState = .startingGlassesRelay
        resetCycleDisplay()
        lastContinuousMessage = "Starting the local Even G2 question relay."
        do {
            try glassesRelay.start()
        } catch {
            continuousState = .failed(error.localizedDescription)
            lastContinuousMessage = error.localizedDescription
            return
        }
        glassesRelay.setMode(captureMode)
        UIApplication.shared.isIdleTimerDisabled = true
        continuousState = .waitingForImage
        lastContinuousMessage = "Even G2 relay ready. Requesting notification permission."
        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let granted = try await notificationService.requestAuthorization()
                guard isCurrentSession(sessionID), !Task.isCancelled else { return }
                lastContinuousMessage = granted
                    ? "G2 relay and notification pop-ups are ready."
                    : "G2 relay ready; enable Pen Camera notifications in iOS Settings for pop-ups."
            } catch {
                lastContinuousMessage = "G2 relay ready; notification permission failed: \(error.localizedDescription)"
            }
            await monitor(sessionID: sessionID, frameProvider: frameProvider)
        }
    }

    func stopContinuous(message: String = "Analysis stopped.") {
        continuousSessionID = nil
        continuousAnalysisProfile = nil
        monitorTask?.cancel()
        uploadTask?.cancel()
        manualBurstTask?.cancel()
        monitorTask = nil
        uploadTask = nil
        manualBurstTask = nil
        manualFinishRequested = false
        activeFrameProvider = nil
        if let currentBatch { try? currentBatch.remove() }
        currentBatch = nil
        continuousRequestInFlight = false
        continuousState = .stopped
        resetCycleDisplay()
        lastContinuousMessage = message
        UIApplication.shared.isIdleTimerDisabled = false
        BackgroundCaptureCoordinator.shared.finish(success: false)
    }

    private func monitor(
        sessionID: UUID,
        frameProvider: @escaping @MainActor @Sendable () -> CameraSample?
    ) async {
        var lastFrameNumber = -1
        var blackStreak = 0
        while isCurrentSession(sessionID), !Task.isCancelled {
            let started = Date()
            if let sample = frameProvider(),
               sample.frameNumber != lastFrameNumber,
               Date().timeIntervalSince(sample.capturedAt) < 5,
               let black = CameraBlackFrameDetector.isBlack(sample.jpeg) {
                lastFrameNumber = sample.frameNumber
                isCurrentFrameBlack = black
                if captureMode == .manualCapture {
                    if let preview = makePreviewJPEG(sample.jpeg) {
                        glassesRelay.publishPreview(preview)
                    }
                    if continuousState != .uploading && manualBurstTask == nil {
                        continuousState = .waitingForImage
                        lastContinuousMessage = "Manual capture: left click takes 3 photos; left double-click uploads."
                    }
                    blackStreak = 0
                } else if continuousState == .uploading {
                    // Update the visible verdict without starting another batch.
                } else if black {
                    if currentBatch != nil {
                        blackStreak += 1
                        lastContinuousMessage = "Black confirmation \(blackStreak)/2."
                        if blackStreak >= 2 {
                            let batch = currentBatch!
                            currentBatch = nil
                            continuousState = .uploading
                            lastContinuousMessage = "Black confirmed. Uploading \(batch.images.count) images once."
                            beginUpload(batch, sessionID: sessionID)
                            blackStreak = 0
                        }
                    } else {
                        continuousState = .waitingForImage
                        lastContinuousMessage = "Black frame: waiting for an image."
                    }
                } else {
                    blackStreak = 0
                    do {
                        if currentBatch == nil {
                            currentBatch = try CameraBatchCapture()
                            continuousState = .recording
                        }
                        if let batch = currentBatch {
                            _ = try batch.append(sample.jpeg)
                            preparedImageCount = batch.images.count
                            BackgroundCaptureCoordinator.shared.reportProgress(
                                imageCount: preparedImageCount, uploading: false
                            )
                        }
                        lastContinuousMessage = "Recording \(preparedImageCount) image(s)."
                    } catch BatchCaptureError.limitReached {
                        lastContinuousMessage = BatchCaptureError.limitReached.localizedDescription
                    } catch {
                        failContinuous(error.localizedDescription, sessionID: sessionID)
                        return
                    }
                }
            } else {
                isCurrentFrameBlack = nil
                lastContinuousMessage = "Waiting for a fresh camera frame."
            }

            let interval: TimeInterval = captureMode == .manualCapture
                ? 1
                : (currentBatch == nil && continuousState != .uploading ? 3 : 1)
            let remaining = max(0, interval - Date().timeIntervalSince(started))
            do { try await Task.sleep(for: .milliseconds(Int64(remaining * 1_000))) }
            catch { return }
        }
    }

    private func beginUpload(_ batch: CameraBatchCapture, sessionID: UUID) {
        guard uploadTask == nil else { return }
        BackgroundCaptureCoordinator.shared.reportProgress(
            imageCount: batch.images.count, uploading: true
        )
        uploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await uploadBatch(batch, sessionID: sessionID)
            guard isCurrentSession(sessionID), !Task.isCancelled else { return }
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard isCurrentSession(sessionID), !Task.isCancelled else { return }
            resetCycleDisplay()
            continuousState = .waitingForImage
            uploadTask = nil
        }
    }

    private func uploadBatch(_ batch: CameraBatchCapture, sessionID: UUID) async {
        defer { try? batch.remove() }
        guard !batch.images.isEmpty, isCurrentSession(sessionID) else { return }
        do {
            let images = try batch.readImages()
            let key = try loadAPIKey()
            guard isCurrentSession(sessionID), !Task.isCancelled else { return }
            continuousRequestCount += 1
            continuousRequestInFlight = true
            hasUploadStarted = true
            hasUploadFinished = false
            uploadOutcome = nil
            cloudRoute = .connecting
            let selectedProfile = continuousAnalysisProfile ?? analysisProfile
            let result = try await analyzer.analyze(
                jpegs: images, apiKey: key, model: model, profile: selectedProfile
            )
            guard isCurrentSession(sessionID), !Task.isCancelled else { return }
            continuousRequestInFlight = false
            hasUploadFinished = true
            cloudRoute = .cellularVerified
            uploadOutcome = "成功"
            lastContinuousResult = result
            glassesRelay.publishBatch(result.questions)
            glassesPushCount += result.questions.count
            for (index, question) in result.questions.enumerated() {
                guard isCurrentSession(sessionID), !Task.isCancelled else { return }
                do {
                    try await notificationService.notify(question: question, sequence: index + 1)
                    notificationCount += 1
                } catch {
                    lastContinuousMessage = "Notification pop-up failed: \(error.localizedDescription)"
                }
            }
            lastContinuousMessage = "Upload finished: sent \(result.questions.count) answer(s) to G2 and notifications."
            onBatchCompleted?(true)
        } catch is CancellationError {
            return
        } catch let error as CellularHTTPError {
            cloudRoute = .failed(error.localizedDescription)
            markUploadFailed(error.localizedDescription, sessionID: sessionID)
        } catch let error as OpenAIExamError {
            updateCloudRoute(after: error)
            markUploadFailed(error.localizedDescription, sessionID: sessionID)
        } catch {
            markUploadFailed(error.localizedDescription, sessionID: sessionID)
        }
    }

    private func markUploadFailed(_ message: String, sessionID: UUID) {
        guard isCurrentSession(sessionID), !Task.isCancelled else { return }
        continuousRequestInFlight = false
        hasUploadFinished = hasUploadStarted
        uploadOutcome = hasUploadStarted ? "失败" : "准备失败"
        lastContinuousMessage = "Upload failed: \(message)"
        onBatchCompleted?(false)
    }

    private func resetCycleDisplay() {
        isCurrentFrameBlack = nil
        hasUploadStarted = false
        hasUploadFinished = false
        preparedImageCount = 0
        uploadOutcome = nil
    }

    private func handleGlassesControl(_ action: GlassesControlAction) {
        guard let sessionID = continuousSessionID, isCurrentSession(sessionID) else { return }
        switch action {
        case let .setMode(mode):
            guard continuousState != .uploading else {
                lastContinuousMessage = "Wait for the current upload before switching modes."
                return
            }
            manualBurstTask?.cancel()
            manualBurstTask = nil
            manualFinishRequested = false
            if let currentBatch { try? currentBatch.remove() }
            currentBatch = nil
            captureMode = mode
            glassesRelay.setMode(mode)
            resetCycleDisplay()
            lastContinuousMessage = mode == .manualCapture
                ? "Manual capture mode selected."
                : "Black-screen detection mode selected."
        case .captureBurst:
            guard captureMode == .manualCapture else { return }
            captureManualBurst(sessionID: sessionID)
        case .finishManualCapture:
            guard captureMode == .manualCapture else { return }
            if manualBurstTask != nil {
                manualFinishRequested = true
                lastContinuousMessage = "Finishing the 3-photo burst, then uploading all photos."
            } else {
                finishManualBatch(sessionID: sessionID)
            }
        case .clearAnswers:
            glassesRelay.clearQuestions()
            lastContinuousResult = nil
            lastContinuousMessage = "Existing G2 answers cleared."
        }
    }

    private func captureManualBurst(sessionID: UUID) {
        guard manualBurstTask == nil, uploadTask == nil, let frameProvider = activeFrameProvider else {
            lastContinuousMessage = "Capture or upload already in progress."
            return
        }
        manualBurstTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if currentBatch == nil { currentBatch = try? CameraBatchCapture() }
            var lastFrame = -1
            for index in 0..<3 {
                guard isCurrentSession(sessionID), !Task.isCancelled else { return }
                if index > 0 {
                    do { try await Task.sleep(for: .milliseconds(500)) }
                    catch { return }
                }
                guard let sample = frameProvider() else { continue }
                if sample.frameNumber == lastFrame {
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                }
                guard let fresh = frameProvider() else { continue }
                lastFrame = fresh.frameNumber
                do {
                    if try currentBatch?.append(fresh.jpeg) == true {
                        preparedImageCount = currentBatch?.images.count ?? 0
                    }
                } catch {
                    lastContinuousMessage = error.localizedDescription
                    break
                }
            }
            manualBurstTask = nil
            lastContinuousMessage = "Captured 3 photos; \(preparedImageCount) queued in this batch."
            if manualFinishRequested {
                manualFinishRequested = false
                finishManualBatch(sessionID: sessionID)
            }
        }
    }

    private func finishManualBatch(sessionID: UUID) {
        guard let batch = currentBatch, !batch.images.isEmpty else {
            lastContinuousMessage = "No manual photos to upload."
            return
        }
        currentBatch = nil
        continuousState = .uploading
        lastContinuousMessage = "Uploading all \(batch.images.count) manually captured photos together."
        beginUpload(batch, sessionID: sessionID)
    }

    private func makePreviewJPEG(_ source: Data) -> Data? {
        guard let image = UIImage(data: source) else { return nil }
        let size = CGSize(width: 288, height: 144)
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            ))
        }
        return rendered.jpegData(compressionQuality: 0.45)
    }

    private func failContinuous(_ message: String, sessionID: UUID) {
        guard isCurrentSession(sessionID) else { return }
        stopContinuous(message: message)
        continuousState = .failed(message)
    }

    private func isCurrentSession(_ sessionID: UUID) -> Bool {
        continuousSessionID == sessionID
    }

    private func loadAPIKey() throws -> String {
        guard let storedKey = try keychain.load(), !storedKey.isEmpty else {
            refreshKeyStatus()
            throw OpenAIExamError.invalidAPIKey
        }
        return storedKey
    }

    private func updateCloudRoute(after error: OpenAIExamError) {
        switch error {
        case .api, .refusal, .missingOutput, .malformedStructuredOutput:
            cloudRoute = .cellularVerified
        case .invalidAPIKey, .invalidModel, .emptyBatch, .invalidHTTPResponse:
            cloudRoute = .cellularRequired
        }
    }

    private func refreshKeyStatus() {
        do { hasStoredAPIKey = try keychain.load()?.isEmpty == false }
        catch { hasStoredAPIKey = false; settingsMessage = error.localizedDescription }
    }
}
