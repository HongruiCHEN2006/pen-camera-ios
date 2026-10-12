import Foundation

struct ExamAnalysisResult: Codable, Equatable, Sendable {
    let questions: [ExamQuestionResult]
}

struct ExamQuestionResult: Codable, Equatable, Identifiable, Sendable {
    let questionNumber: String
    let opening: String
    let questionType: String
    let correctAnswer: String
    let selectedOptions: [String]
    let choicePreviews: [ChoicePreview]
    let certainty: String

    struct ChoicePreview: Codable, Equatable, Sendable {
        let label: String
        let opening: String
    }

    var displayAnswer: String {
        let labels = selectedOptions.joined(separator: ", ")
        let options = choicePreviews.map { "\($0.label). \($0.opening)" }.joined(separator: "；")
        let answer: String
        switch questionType {
        case "single_choice": answer = options.isEmpty ? labels : options
        case "multiple_choice": answer = options.isEmpty ? labels : "\(labels)（\(options)）"
        default: answer = correctAnswer
        }
        return certainty == "uncertain" ? "无法确定。基于现有材料：\(answer)" : answer
    }

    var id: String { questionNumber + "-" + opening + "-" + selectedOptions.joined(separator: "|") + correctAnswer }

    enum CodingKeys: String, CodingKey {
        case questionNumber = "question_number"
        case opening
        case questionType = "question_type"
        case correctAnswer = "correct_answer"
        case selectedOptions = "selected_options"
        case choicePreviews = "choice_previews"
        case certainty
    }
}

enum OpenAIExamError: LocalizedError, Equatable {
    case invalidAPIKey
    case invalidModel
    case emptyBatch
    case invalidHTTPResponse
    case api(statusCode: Int, message: String)
    case refusal(String)
    case missingOutput
    case malformedStructuredOutput

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: "OpenAI API Key is empty. Open Settings and save a key first."
        case .invalidModel: "The model name is empty."
        case .emptyBatch: "No camera images are available for analysis."
        case .invalidHTTPResponse: "OpenAI returned an invalid HTTP response."
        case let .api(statusCode, message): "OpenAI API error \(statusCode): \(message)"
        case let .refusal(message): "The model declined the image request: \(message)"
        case .missingOutput: "OpenAI returned no text result."
        case .malformedStructuredOutput: "OpenAI returned an invalid question list."
        }
    }
}

actor OpenAIExamAnalyzer {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let defaultModel = "gpt-6.1-sol"

    private let cellularClient: CellularHTTPSClient

    init(cellularClient: CellularHTTPSClient = CellularHTTPSClient()) {
        self.cellularClient = cellularClient
    }

    func analyze(
        jpeg: Data, apiKey: String, model: String, profile: AnalysisProfile = .general
    ) async throws -> ExamAnalysisResult {
        try await analyze(jpegs: [jpeg], apiKey: apiKey, model: model, profile: profile)
    }

    func analyze(
        jpegs: [Data], apiKey: String, model: String, profile: AnalysisProfile = .general
    ) async throws -> ExamAnalysisResult {
        let request = try Self.makeRequest(
            jpegs: jpegs, apiKey: apiKey, model: model, profile: profile
        )
        let response = try await cellularClient.send(request)
        return try Self.parseResponse(data: response.body, statusCode: response.statusCode)
    }

    static func makeRequest(
        jpeg: Data, apiKey: String, model: String, profile: AnalysisProfile = .general
    ) throws -> URLRequest {
        try makeRequest(jpegs: [jpeg], apiKey: apiKey, model: model, profile: profile)
    }

    static func makeRequest(
        jpegs: [Data], apiKey: String, model: String, profile: AnalysisProfile = .general
    ) throws -> URLRequest {
        guard !jpegs.isEmpty else { throw OpenAIExamError.emptyBatch }
        guard apiKey.rangeOfCharacter(from: .newlines) == nil else {
            throw OpenAIExamError.invalidAPIKey
        }
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw OpenAIExamError.invalidAPIKey }
        guard !cleanModel.isEmpty else { throw OpenAIExamError.invalidModel }

        var content: [[String: Any]] = []
        for jpeg in jpegs {
            content.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())",
                "detail": "high"
            ])
        }
        let body: [String: Any] = [
            "model": cleanModel,
            "reasoning": ["effort": "medium"],
            "store": false,
            "instructions": profile.instructions,
            "input": [["role": "user", "content": content]],
            "text": ["format": [
                "type": "json_schema",
                "name": "confirmed_exam_questions",
                "strict": true,
                "schema": makeResultSchema()
            ]]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseResponse(data: Data, statusCode: Int) throws -> ExamAnalysisResult {
        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw OpenAIExamError.api(statusCode: statusCode, message: message)
        }
        guard let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data) else {
            throw OpenAIExamError.malformedStructuredOutput
        }
        let contentItems = envelope.output.flatMap { $0.content ?? [] }
        if let refusal = contentItems.compactMap(\.refusal).first, !refusal.isEmpty {
            throw OpenAIExamError.refusal(refusal)
        }
        guard let text = contentItems.first(where: { $0.type == "output_text" })?.text else {
            throw OpenAIExamError.missingOutput
        }
        guard let textData = text.data(using: .utf8),
              let result = try? JSONDecoder().decode(ExamAnalysisResult.self, from: textData) else {
            throw OpenAIExamError.malformedStructuredOutput
        }
        var seen = Set<String>()
        let cleaned = try result.questions.map { question in
            let number = question.questionNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let opening = question.opening.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = question.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSingleChoice = question.questionType == "single_choice"
            let isMultipleChoice = question.questionType == "multiple_choice"
            let isChoice = isSingleChoice || isMultipleChoice
            let isCertain = question.certainty == "certain"
            let selectedOptions = question.selectedOptions.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let validSelectedOptions = !selectedOptions.isEmpty
                && selectedOptions.allSatisfy(Self.isValidOptionLabel)
                && Set(selectedOptions).count == selectedOptions.count
            let previews = question.choicePreviews.map {
                ExamQuestionResult.ChoicePreview(
                    label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                    opening: $0.opening.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard !number.isEmpty, !opening.isEmpty,
                  ["single_choice", "multiple_choice", "other"].contains(question.questionType),
                  ["certain", "uncertain"].contains(question.certainty),
                  !isChoice || (answer.isEmpty && validSelectedOptions),
                  !isSingleChoice || selectedOptions.count == 1,
                  !isMultipleChoice || !selectedOptions.isEmpty,
                  previews.allSatisfy({
                      Self.isValidOptionLabel($0.label)
                          && selectedOptions.contains($0.label)
                          && !$0.opening.isEmpty
                  }),
                  Set(previews.map(\.label)).count == previews.count,
                  !isCertain || !isChoice || previews.map(\.label) == selectedOptions,
                  isChoice || (!answer.isEmpty && selectedOptions.isEmpty && previews.isEmpty) else {
                throw OpenAIExamError.malformedStructuredOutput
            }
            return ExamQuestionResult(
                questionNumber: number, opening: opening, questionType: question.questionType,
                correctAnswer: answer, selectedOptions: selectedOptions,
                choicePreviews: previews, certainty: question.certainty
            )
        }
        let unique = cleaned.filter { question in
            let key = question.questionNumber + "|" + question.opening.lowercased()
            return seen.insert(key).inserted
        }
        return ExamAnalysisResult(questions: unique)
    }

    private static func isValidOptionLabel(_ label: String) -> Bool {
        !label.isEmpty
            && label.count <= 16
            && label.rangeOfCharacter(from: .newlines) == nil
    }

    private static func makeResultSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": ["questions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "question_number": ["type": "string"],
                        "opening": ["type": "string"],
                        "question_type": ["type": "string", "enum": ["single_choice", "multiple_choice", "other"]],
                        "correct_answer": ["type": "string"],
                        "selected_options": ["type": "array", "items": ["type": "string"]],
                        "choice_previews": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "label": ["type": "string"],
                                    "opening": ["type": "string"]
                                ],
                                "required": ["label", "opening"],
                                "additionalProperties": false
                            ]
                        ],
                        "certainty": ["type": "string", "enum": ["certain", "uncertain"]]
                    ],
                    "required": ["question_number", "opening", "question_type", "correct_answer", "selected_options", "choice_previews", "certainty"],
                    "additionalProperties": false
                ]
            ]],
            "required": ["questions"],
            "additionalProperties": false
        ]
    }

    private struct ResponseEnvelope: Decodable {
        let output: [OutputItem]
        struct OutputItem: Decodable { let content: [ContentItem]? }
        struct ContentItem: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }
    }

    private struct APIErrorEnvelope: Decodable {
        let error: APIError
        struct APIError: Decodable { let message: String }
    }
}
