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
        case requestingNotificationPermission
        case waitingForImage
        case recording
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .requestingNotificationPermission: "Requesting notification permission"
            case .waitingForImage: "Waiting for image (3s checks)"
            case .recording: "Recording (1s samples)"
            case .failed: "Stopped with error"
            }
        }

        var isActive: Bool {
            switch self {
            case .requestingNotificationPermission, .waitingForImage, .recording: true
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
    @Published private(set) var notificationCount = 0
    @Published private(set) var capturedFrameCount = 0
    @Published private(set) var pendingBatchCount = 0
    @Published private(set) var continuousRequestInFlight = false
    @Published private(set) var lastContinuousMessage: String?
    @Published private(set) var lastContinuousResult: ExamAnalysisResult?
    @Published var apiKeyDraft = ""
    @Published var model: String
    @Published private(set) var settingsMessage: String?

    private let keychain = KeychainStore(service: "com.hongrui.pencamera.openai", account: "api-key")
    private let analyzer: OpenAIExamAnalyzer
    private let notificationService: QuestionNotificationService
    private var capturedJPEG: Data?
    private var analysisTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var continuousSessionID: UUID?
    private var currentBatch: CameraBatchCapture?
    private var pendingBatches: [CameraBatchCapture] = []
    private var uploadPaused = false
    private var notificationProgress: [URL: Int] = [:]

    init(analyzer: OpenAIExamAnalyzer = OpenAIExamAnalyzer()) {
        self.analyzer = analyzer
        notificationService = .shared
        model = OpenAIExamAnalyzer.defaultModel
        pendingBatches = CameraBatchCapture.recover()
        pendingBatchCount = pendingBatches.count
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
        cloudRoute = .connecting
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await analyzer.analyze(jpeg: jpeg, apiKey: key, model: selectedModel)
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
        continuousState = .requestingNotificationPermission
        lastContinuousMessage = "Waiting for iOS notification permission."
        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let granted = try await notificationService.requestAuthorization()
                guard isCurrentSession(sessionID) else { return }
                guard granted else {
                    failContinuous("Enable Pen Camera notifications in iOS Settings.", sessionID: sessionID)
                    return
                }
                UIApplication.shared.isIdleTimerDisabled = true
                continuousState = .waitingForImage
                startUploadIfNeeded(sessionID: sessionID)
                await monitor(sessionID: sessionID, frameProvider: frameProvider)
            } catch {
                guard isCurrentSession(sessionID) else { return }
                failContinuous(error.localizedDescription, sessionID: sessionID)
            }
        }
    }

    func stopContinuous(message: String = "Analysis stopped. Unfinished images remain available for retry.") {
        continuousSessionID = nil
        monitorTask?.cancel()
        uploadTask?.cancel()
        monitorTask = nil
        uploadTask = nil
        if let currentBatch, !currentBatch.images.isEmpty {
            pendingBatches.append(currentBatch)
        }
        currentBatch = nil
        pendingBatchCount = pendingBatches.count
        capturedFrameCount = 0
        continuousRequestInFlight = false
        continuousState = .stopped
        lastContinuousMessage = message
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func retryPendingBatches() {
        guard isContinuousActive, !pendingBatches.isEmpty else { return }
        uploadPaused = false
        guard let sessionID = continuousSessionID else { return }
        startUploadIfNeeded(sessionID: sessionID)
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
                if black {
                    if currentBatch != nil {
                        blackStreak += 1
                        if blackStreak >= 2 {
                            finishBatch(sessionID: sessionID)
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
                            capturedFrameCount = 0
                            continuousState = .recording
                        }
                        if let batch = currentBatch, try batch.append(sample.jpeg) {
                            capturedFrameCount = batch.images.count
                        }
                        lastContinuousMessage = "Recording \(capturedFrameCount) image(s) for this batch."
                    } catch BatchCaptureError.limitReached {
                        lastContinuousMessage = BatchCaptureError.limitReached.localizedDescription
                    } catch {
                        failContinuous(error.localizedDescription, sessionID: sessionID)
                        return
                    }
                }
            } else if currentBatch == nil {
                lastContinuousMessage = "Waiting for a fresh camera frame."
            }

            let interval: TimeInterval = currentBatch == nil ? 3 : 1
            let remaining = max(0, interval - Date().timeIntervalSince(started))
            do { try await Task.sleep(for: .milliseconds(Int64(remaining * 1_000))) }
            catch { return }
        }
    }

    private func finishBatch(sessionID: UUID) {
        guard let batch = currentBatch else { return }
        currentBatch = nil
        capturedFrameCount = 0
        continuousState = .waitingForImage
        guard !batch.images.isEmpty else { return }
        pendingBatches.append(batch)
        pendingBatchCount = pendingBatches.count
        lastContinuousMessage = "Black frame confirmed. Queued \(batch.images.count) images for one API request."
        startUploadIfNeeded(sessionID: sessionID)
    }

    private func startUploadIfNeeded(sessionID: UUID) {
        guard isCurrentSession(sessionID), !uploadPaused,
              uploadTask == nil, !pendingBatches.isEmpty else { return }
        uploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await uploadPending(sessionID: sessionID)
        }
    }

    private func uploadPending(sessionID: UUID) async {
        while isCurrentSession(sessionID), !Task.isCancelled,
              !uploadPaused, let batch = pendingBatches.first {
            do {
                let images = try batch.readImages()
                let key = try loadAPIKey()
                continuousRequestCount += 1
                continuousRequestInFlight = true
                cloudRoute = .connecting
                let result = try await analyzer.analyze(jpegs: images, apiKey: key, model: model)
                guard isCurrentSession(sessionID), !Task.isCancelled else { return }
                continuousRequestInFlight = false
                cloudRoute = .cellularVerified
                lastContinuousResult = result
                let alreadyNotified = notificationProgress[batch.directory] ?? 0
                for (index, question) in result.questions.enumerated() where index >= alreadyNotified {
                    guard isCurrentSession(sessionID), !Task.isCancelled else { return }
                    try await notificationService.notify(question: question, sequence: index + 1)
                    notificationProgress[batch.directory] = index + 1
                    notificationCount += 1
                }
                pendingBatches.removeFirst()
                notificationProgress.removeValue(forKey: batch.directory)
                pendingBatchCount = pendingBatches.count
                try? batch.remove()
                lastContinuousMessage = "Analysis complete: \(result.questions.count) separate iOS notification(s)."
            } catch is CancellationError {
                return
            } catch let error as CellularHTTPError {
                cloudRoute = .failed(error.localizedDescription)
                pauseUpload(error.localizedDescription)
            } catch let error as OpenAIExamError {
                updateCloudRoute(after: error)
                pauseUpload(error.localizedDescription)
            } catch {
                pauseUpload(error.localizedDescription)
            }
        }
        uploadTask = nil
    }

    private func pauseUpload(_ message: String) {
        continuousRequestInFlight = false
        uploadPaused = true
        lastContinuousMessage = "Upload failed; saved batch can be retried. \(message)"
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
