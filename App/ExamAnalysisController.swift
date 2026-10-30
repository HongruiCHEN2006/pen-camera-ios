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
    @Published private(set) var continuousState: ContinuousState = .stopped {
        didSet { publishGlassesStatus() }
    }
    @Published private(set) var continuousRequestCount = 0
    @Published private(set) var glassesPushCount = 0
    @Published private(set) var notificationCount = 0
    @Published private(set) var continuousRequestInFlight = false {
        didSet { publishGlassesStatus() }
    }
    @Published private(set) var isCurrentFrameBlack: Bool? {
        didSet { publishGlassesStatus() }
    }
    @Published private(set) var hasUploadStarted = false {
        didSet { publishGlassesStatus() }
    }
    @Published private(set) var hasUploadFinished = false {
        didSet { publishGlassesStatus() }
    }
    @Published private(set) var preparedImageCount = 0 {
        didSet { publishGlassesStatus() }
    }
    @Published private(set) var uploadOutcome: String? {
        didSet { publishGlassesStatus() }
    }
    @Published private(set) var lastContinuousMessage: String?
    @Published private(set) var lastContinuousResult: ExamAnalysisResult?
    @Published var apiKeyDraft = ""
    @Published var model: String
    @Published private(set) var analysisProfile: AnalysisProfile {
        didSet {
            preferences.set(analysisProfile.rawValue, forKey: Self.profilePreferenceKey)
            glassesRelay.updateConfiguration(profile: analysisProfile, uploadMode: uploadMode)
        }
    }
    @Published private(set) var uploadMode: AnalysisUploadMode {
        didSet {
            preferences.set(uploadMode.rawValue, forKey: Self.uploadModePreferenceKey)
            glassesRelay.updateConfiguration(profile: analysisProfile, uploadMode: uploadMode)
        }
    }
    @Published private(set) var settingsMessage: String?

    private static let profilePreferenceKey = "analysis-profile"
    private static let uploadModePreferenceKey = "analysis-upload-mode"
    private let keychain = KeychainStore(service: "com.hongrui.pencamera.openai", account: "api-key")
    private let analyzer: OpenAIExamAnalyzer
    private let glassesRelay: GlassesRelayServer
    private let notificationService: QuestionNotificationService
    private let preferences: UserDefaults
    private var capturedJPEG: Data?
    private var analysisTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var continuousSessionID: UUID?
    private var currentBatch: CameraBatchCapture?
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
        uploadMode = AnalysisUploadMode(
            rawValue: preferences.string(forKey: Self.uploadModePreferenceKey) ?? ""
        ) ?? .images
        glassesRelay.updateConfiguration(profile: analysisProfile, uploadMode: uploadMode)
        glassesRelay.setConfigurationChangeHandler { [weak self] profile, uploadMode in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let profile { self.analysisProfile = profile }
                if let uploadMode { self.uploadMode = uploadMode }
            }
        }
        refreshKeyStatus()
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
        monitorTask?.cancel()
        uploadTask?.cancel()
        monitorTask = nil
        uploadTask = nil
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
                if continuousState == .uploading {
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
                            let appended = try batch.append(sample.jpeg)
                            preparedImageCount = batch.images.count
                            BackgroundCaptureCoordinator.shared.reportProgress(
                                imageCount: preparedImageCount, uploading: false
                            )
                            if appended {
                                let frameIndex = batch.images.count
                                do {
                                    let frame = try await AppleVisionOCR.recognize(
                                        jpeg: sample.jpeg, frameIndex: frameIndex
                                    )
                                    guard isCurrentSession(sessionID), currentBatch === batch else { return }
                                    batch.appendOCR(frame)
                                    glassesRelay.updateOCRPreview(frame)
                                } catch {
                                    lastContinuousMessage = "Apple Vision OCR failed for frame \(frameIndex): \(error.localizedDescription)"
                                }
                            }
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

            let interval: TimeInterval = currentBatch == nil && continuousState != .uploading ? 3 : 1
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
            let key = try loadAPIKey()
            guard isCurrentSession(sessionID), !Task.isCancelled else { return }
            continuousRequestCount += 1
            continuousRequestInFlight = true
            hasUploadStarted = true
            hasUploadFinished = false
            uploadOutcome = nil
            cloudRoute = .connecting
            let selectedProfile = analysisProfile
            let selectedUploadMode = uploadMode
            let result: ExamAnalysisResult
            switch selectedUploadMode {
            case .images:
                result = try await analyzer.analyze(
                    jpegs: batch.readImages(),
                    apiKey: key,
                    model: model,
                    profile: selectedProfile
                )
            case .appleVision:
                result = try await analyzer.analyze(
                    ocrFrames: batch.ocrFrames,
                    apiKey: key,
                    model: model,
                    profile: selectedProfile
                )
            }
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
        glassesRelay.updateOCRPreview(nil)
    }

    private func publishGlassesStatus() {
        let uploadState: String
        if let uploadOutcome {
            uploadState = uploadOutcome == "成功" ? "success" : "failed"
        } else if continuousRequestInFlight || continuousState == .uploading {
            uploadState = "uploading"
        } else if hasUploadStarted {
            uploadState = "started"
        } else {
            uploadState = "not_started"
        }
        glassesRelay.updateAnalysisStatus(
            isBlack: isCurrentFrameBlack,
            uploadState: uploadState,
            imageCount: preparedImageCount
        )
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
        case .invalidAPIKey, .invalidModel, .emptyBatch, .emptyOCR, .invalidHTTPResponse:
            cloudRoute = .cellularRequired
        }
    }

    private func refreshKeyStatus() {
        do { hasStoredAPIKey = try keychain.load()?.isEmpty == false }
        catch { hasStoredAPIKey = false; settingsMessage = error.localizedDescription }
    }
}
