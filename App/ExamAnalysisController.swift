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
        case running
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .requestingNotificationPermission: "Requesting notification permission"
            case .running: "Running every 3 seconds"
            case .failed: "Stopped with error"
            }
        }

        var isActive: Bool {
            switch self {
            case .requestingNotificationPermission, .running: true
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
    @Published private(set) var historyCount = 0
    @Published private(set) var continuousRequestInFlight = false
    @Published private(set) var lastContinuousMessage: String?
    @Published private(set) var lastContinuousResult: ExamAnalysisResult?
    @Published var apiKeyDraft = ""
    @Published var model: String
    @Published private(set) var settingsMessage: String?

    private let keychain = KeychainStore(
        service: "com.hongrui.pencamera.openai",
        account: "api-key"
    )
    private let analyzer: OpenAIExamAnalyzer
    private let notificationService: QuestionNotificationService
    private let questionHistory: AnalyzedQuestionHistory
    private var capturedJPEG: Data?
    private var analysisTask: Task<Void, Never>?
    private var continuousTask: Task<Void, Never>?
    private var continuousSessionID: UUID?

    init(
        analyzer: OpenAIExamAnalyzer = OpenAIExamAnalyzer(),
        notificationService: QuestionNotificationService? = nil,
        questionHistory: AnalyzedQuestionHistory? = nil
    ) {
        self.analyzer = analyzer
        self.notificationService = notificationService ?? .shared
        self.questionHistory = questionHistory ?? AnalyzedQuestionHistory()
        let savedModel = UserDefaults.standard.string(forKey: "openai-model")
        model = savedModel?.isEmpty == false ? savedModel! : OpenAIExamAnalyzer.defaultModel
        historyCount = self.questionHistory.count
        refreshKeyStatus()
    }

    var isAnalyzing: Bool { phase == .analyzing }
    var isContinuousActive: Bool { continuousState.isActive }

    func saveSettings() -> Bool {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty else {
            settingsMessage = "Model name cannot be empty."
            return false
        }

        do {
            let cleanKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanKey.isEmpty {
                try keychain.save(cleanKey)
                apiKeyDraft = ""
            } else if !hasStoredAPIKey {
                settingsMessage = "Enter an OpenAI API Key."
                return false
            }
            model = cleanModel
            UserDefaults.standard.set(cleanModel, forKey: "openai-model")
            refreshKeyStatus()
            settingsMessage = "Saved locally. The API Key is stored in iOS Keychain."
            return true
        } catch {
            settingsMessage = error.localizedDescription
            return false
        }
    }

    func removeAPIKey() {
        stopContinuous(message: "Continuous analysis stopped because the API Key was removed.")
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
        do {
            key = try loadAPIKey()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

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

    func startContinuous(
        frameProvider: @escaping @MainActor @Sendable () -> Data?
    ) {
        guard !isContinuousActive, !isAnalyzing else { return }
        guard frameProvider() != nil else {
            continuousState = .failed("No complete camera frame is available yet.")
            return
        }

        let key: String
        do {
            key = try loadAPIKey()
        } catch {
            continuousState = .failed(error.localizedDescription)
            return
        }

        continuousTask?.cancel()
        let sessionID = UUID()
        continuousSessionID = sessionID
        continuousState = .requestingNotificationPermission
        lastContinuousMessage = "Waiting for iOS notification permission."
        let selectedModel = model

        continuousTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let granted = try await notificationService.requestAuthorization()
                guard isCurrentContinuousSession(sessionID) else { return }
                guard granted else {
                    failContinuous(
                        "iOS notification permission is denied. Enable notifications for Pen Camera in Settings.",
                        sessionID: sessionID
                    )
                    return
                }

                UIApplication.shared.isIdleTimerDisabled = true
                continuousState = .running
                lastContinuousMessage = "Continuous analysis is active in the foreground."
                await runContinuousLoop(
                    sessionID: sessionID,
                    apiKey: key,
                    model: selectedModel,
                    frameProvider: frameProvider
                )
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentContinuousSession(sessionID) else { return }
                failContinuous(error.localizedDescription, sessionID: sessionID)
            }
        }
    }

    func stopContinuous(message: String = "Continuous analysis stopped.") {
        continuousSessionID = nil
        continuousTask?.cancel()
        continuousTask = nil
        continuousRequestInFlight = false
        continuousState = .stopped
        lastContinuousMessage = message
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func clearQuestionHistory() {
        guard !isContinuousActive else { return }
        questionHistory.clear()
        historyCount = 0
        lastContinuousMessage = "Analyzed-question history cleared."
    }

    private func runContinuousLoop(
        sessionID: UUID,
        apiKey: String,
        model: String,
        frameProvider: @escaping @MainActor @Sendable () -> Data?
    ) async {
        while isCurrentContinuousSession(sessionID), !Task.isCancelled {
            let cycleStartedAt = Date()

            if let jpeg = frameProvider() {
                continuousRequestCount += 1
                continuousRequestInFlight = true
                cloudRoute = .connecting

                do {
                    let result = try await analyzer.analyze(
                        jpeg: jpeg,
                        apiKey: apiKey,
                        model: model
                    )
                    guard isCurrentContinuousSession(sessionID), !Task.isCancelled else { return }
                    continuousRequestInFlight = false
                    cloudRoute = .cellularVerified
                    lastContinuousResult = result
                    await notifyForNewQuestions(in: result, sessionID: sessionID)
                } catch is CancellationError {
                    return
                } catch let error as CellularHTTPError {
                    continuousRequestInFlight = false
                    cloudRoute = .failed(error.localizedDescription)
                    lastContinuousMessage = error.localizedDescription
                } catch let error as OpenAIExamError {
                    continuousRequestInFlight = false
                    updateCloudRoute(after: error)
                    if case let .api(statusCode, _) = error, statusCode == 401 || statusCode == 403 {
                        failContinuous(error.localizedDescription, sessionID: sessionID)
                        return
                    }
                    lastContinuousMessage = error.localizedDescription
                } catch {
                    continuousRequestInFlight = false
                    lastContinuousMessage = error.localizedDescription
                }
            } else {
                lastContinuousMessage = "Waiting for a complete camera frame."
            }

            guard isCurrentContinuousSession(sessionID), !Task.isCancelled else { return }
            let elapsed = Date().timeIntervalSince(cycleStartedAt)
            let remainingMilliseconds = max(0, Int64(((3 - elapsed) * 1_000).rounded()))
            if remainingMilliseconds > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(remainingMilliseconds))
                } catch {
                    return
                }
            }
        }
    }

    private func notifyForNewQuestions(
        in result: ExamAnalysisResult,
        sessionID: UUID
    ) async {
        let completeQuestions = result.completeQuestions
        guard !completeQuestions.isEmpty else {
            lastContinuousMessage = "No complete readable question was found in the latest frame."
            return
        }

        var newNotificationCount = 0
        for question in completeQuestions {
            guard isCurrentContinuousSession(sessionID), !Task.isCancelled else { return }
            guard !questionHistory.contains(question) else { continue }
            do {
                try await notificationService.notify(
                    question: question,
                    sequence: newNotificationCount + 1
                )
                questionHistory.insert(question)
                historyCount = questionHistory.count
                notificationCount += 1
                newNotificationCount += 1
            } catch {
                lastContinuousMessage = "Could not schedule an iOS notification: \(error.localizedDescription)"
            }
        }

        if newNotificationCount > 0 {
            lastContinuousMessage = "Scheduled \(newNotificationCount) new iOS notification(s)."
        } else if completeQuestions.allSatisfy({ questionHistory.contains($0) }) {
            lastContinuousMessage = "All complete questions in the latest frame were already analyzed."
        }
    }

    private func failContinuous(_ message: String, sessionID: UUID) {
        guard isCurrentContinuousSession(sessionID) else { return }
        continuousSessionID = nil
        continuousTask = nil
        continuousRequestInFlight = false
        continuousState = .failed(message)
        lastContinuousMessage = message
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func isCurrentContinuousSession(_ sessionID: UUID) -> Bool {
        continuousSessionID == sessionID
    }

    private func loadAPIKey() throws -> String {
        do {
            guard let storedKey = try keychain.load(), !storedKey.isEmpty else {
                refreshKeyStatus()
                throw OpenAIExamError.invalidAPIKey
            }
            return storedKey
        } catch let error as OpenAIExamError {
            throw error
        } catch {
            throw error
        }
    }

    private func updateCloudRoute(after error: OpenAIExamError) {
        switch error {
        case .api, .refusal, .missingOutput, .malformedStructuredOutput:
            cloudRoute = .cellularVerified
        case .invalidAPIKey, .invalidModel, .invalidHTTPResponse:
            cloudRoute = .cellularRequired
        }
    }

    private func refreshKeyStatus() {
        do {
            hasStoredAPIKey = try keychain.load()?.isEmpty == false
        } catch {
            hasStoredAPIKey = false
            settingsMessage = error.localizedDescription
        }
    }
}
