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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var cloudRoute: CloudRoute = .cellularRequired
    @Published var apiKeyDraft = ""
    @Published var model: String
    @Published private(set) var settingsMessage: String?

    private let keychain = KeychainStore(
        service: "com.hongrui.pencamera.openai",
        account: "api-key"
    )
    private let analyzer: OpenAIExamAnalyzer
    private var capturedJPEG: Data?
    private var analysisTask: Task<Void, Never>?

    init(analyzer: OpenAIExamAnalyzer = OpenAIExamAnalyzer()) {
        self.analyzer = analyzer
        let savedModel = UserDefaults.standard.string(forKey: "openai-model")
        model = savedModel?.isEmpty == false ? savedModel! : OpenAIExamAnalyzer.defaultModel
        refreshKeyStatus()
    }

    var isAnalyzing: Bool { phase == .analyzing }

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
        analysisTask?.cancel()
        capturedJPEG = jpeg
        capturedImage = UIImage(data: jpeg)
        phase = .analyzing

        let key: String
        do {
            guard let storedKey = try keychain.load(), !storedKey.isEmpty else {
                phase = .failed(OpenAIExamError.invalidAPIKey.localizedDescription)
                refreshKeyStatus()
                return
            }
            key = storedKey
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
                switch error {
                case .api, .refusal, .missingOutput, .malformedStructuredOutput:
                    cloudRoute = .cellularVerified
                case .invalidAPIKey, .invalidModel, .invalidHTTPResponse:
                    cloudRoute = .cellularRequired
                }
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

    private func refreshKeyStatus() {
        do {
            hasStoredAPIKey = try keychain.load()?.isEmpty == false
        } catch {
            hasStoredAPIKey = false
            settingsMessage = error.localizedDescription
        }
    }
}
