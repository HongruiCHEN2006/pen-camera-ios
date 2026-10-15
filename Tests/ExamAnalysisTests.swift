import Foundation
import XCTest
@testable import PenCamera

final class ExamAnalysisTests: XCTestCase {
    func testRoutePoliciesRequireSeparateInterfaces() {
        XCTAssertEqual(NetworkRoutePolicy.cameraWiFiParameters().requiredInterfaceType, .wifi)
        XCTAssertEqual(NetworkRoutePolicy.cloudCellularParameters().requiredInterfaceType, .cellular)
    }

    func testBatchRequestUsesSolMediumReasoningAndHighDetailForEachImage() throws {
        let images = [Data([0xFF, 0xD8, 1, 0xFF, 0xD9]), Data([0xFF, 0xD8, 2, 0xFF, 0xD9])]
        let request = try OpenAIExamAnalyzer.makeRequest(
            jpegs: images, apiKey: "sk-test-only", model: OpenAIExamAnalyzer.defaultModel
        )
        XCTAssertEqual(request.url, OpenAIExamAnalyzer.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-only")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(object["store"] as? Bool, false)
        let reasoning = try XCTUnwrap(object["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "medium")
        let instructions = try XCTUnwrap(object["instructions"] as? String)
        XCTAssertTrue(instructions.contains("selected_options"))
        XCTAssertTrue(instructions.contains("not restricted to A-E"))

        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let suppliedImages = content.filter { $0["type"] as? String == "input_image" }
        XCTAssertEqual(suppliedImages.count, 2)
        for (index, image) in suppliedImages.enumerated() {
            XCTAssertEqual(image["detail"] as? String, "high")
            XCTAssertEqual(
                image["image_url"] as? String,
                "data:image/jpeg;base64,\(images[index].base64EncodedString())"
            )
        }

        let text = try XCTUnwrap(object["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let questions = try XCTUnwrap(properties["questions"] as? [String: Any])
        let items = try XCTUnwrap(questions["items"] as? [String: Any])
        XCTAssertEqual(items["required"] as? [String], [
            "question_number", "opening", "question_type", "correct_answer",
            "selected_options", "choice_previews", "certainty"
        ])
    }

    func testCS0447RequestUsesDedicated32BitMIPSInstructionsWithoutRetrieval() throws {
        let request = try OpenAIExamAnalyzer.makeRequest(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            apiKey: "sk-test-only",
            model: OpenAIExamAnalyzer.defaultModel,
            profile: .cs0447
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let instructions = try XCTUnwrap(object["instructions"] as? String)
        XCTAssertTrue(instructions.contains("CS 0447"))
        XCTAssertTrue(instructions.contains("assume 32-bit MIPS"))
        XCTAssertTrue(instructions.contains("word is 32 bits"))
        XCTAssertTrue(instructions.contains("does not establish endianness"))
        XCTAssertTrue(instructions.contains("Do not use web search, file search, retrieval"))
        XCTAssertTrue(instructions.contains("Never claim code was executed or simulator-verified"))
    }

    func testIntroPsychologyRequestUsesDedicatedCourseInstructionsAndSharedSchemaRules() throws {
        let request = try OpenAIExamAnalyzer.makeRequest(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            apiKey: "sk-test-only",
            model: OpenAIExamAnalyzer.defaultModel,
            profile: .introPsychology
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let instructions = try XCTUnwrap(object["instructions"] as? String)

        XCTAssertTrue(instructions.contains("introductory psychology course"))
        XCTAssertTrue(instructions.contains("Course-specific emphasis: Learning Principles"))
        XCTAssertTrue(instructions.contains("Course-specific emphasis: Memory"))
        XCTAssertTrue(instructions.contains("Course-specific emphasis: Thinking and Cognition"))
        XCTAssertTrue(instructions.contains("fixed-ratio, variable-ratio"))
        XCTAssertTrue(instructions.contains("prototype theory from exemplar theory"))
        XCTAssertTrue(instructions.contains("minor visual imperfections"))
        XCTAssertTrue(instructions.contains("Treat a matching question as question_type=\"other\""))
        XCTAssertTrue(instructions.contains("not restricted to A-E"))
        XCTAssertTrue(instructions.contains("Return only JSON matching the supplied schema"))
        XCTAssertTrue(instructions.contains("Do not use web search, file search, retrieval"))
        XCTAssertFalse(instructions.contains("CS 0447"))
    }

    func testAllAnalysisProfilesAppearInCategoryPickerOrder() {
        XCTAssertEqual(
            AnalysisProfile.allCases,
            [.general, .cs0447, .introPsychology]
        )
        XCTAssertEqual(AnalysisProfile.introPsychology.displayName, "Intro to Psychology")
    }

    func testParsesMultipleLetterChoicesAndRemovesDuplicatesWithinBatch() throws {
        let text = #"{"questions":[{"question_number":"2","opening":"Find the value","question_type":"multiple_choice","correct_answer":"","selected_options":["A","G"],"choice_previews":[{"label":"A","opening":"cell membrane"},{"label":"G","opening":"nuclear envelope"}],"certainty":"certain"},{"question_number":"x","opening":"求图中阴影面积","question_type":"other","correct_answer":"24 平方厘米","selected_options":[],"choice_previews":[],"certainty":"certain"},{"question_number":"2","opening":"Find the value","question_type":"multiple_choice","correct_answer":"","selected_options":["A","G"],"choice_previews":[{"label":"A","opening":"cell membrane"},{"label":"G","opening":"nuclear envelope"}],"certainty":"certain"}]}"#
        let result = try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)
        XCTAssertEqual(result.questions.count, 2)
        XCTAssertEqual(result.questions[0].displayAnswer, "A, G（A. cell membrane；G. nuclear envelope）")
        XCTAssertEqual(result.questions[1].displayAnswer, "24 平方厘米")
    }

    func testNumericOptionLabelsRemainUnambiguous() throws {
        let text = #"{"questions":[{"question_number":"7","opening":"Select all valid loads","question_type":"multiple_choice","correct_answer":"","selected_options":["1","3","10"],"choice_previews":[{"label":"1","opening":"Load signed"},{"label":"3","opening":"Load unsigned"},{"label":"10","opening":"Store word"}],"certainty":"certain"}]}"#
        let result = try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)
        XCTAssertEqual(result.questions.first?.selectedOptions, ["1", "3", "10"])
        XCTAssertEqual(
            result.questions.first?.displayAnswer,
            "1, 3, 10（1. Load signed；3. Load unsigned；10. Store word）"
        )
    }

    func testAcceptsMultiCharacterSingleChoiceIdentifier() throws {
        let text = #"{"questions":[{"question_number":"4","opening":"Choose one","question_type":"single_choice","correct_answer":"","selected_options":["AA"],"choice_previews":[{"label":"AA","opening":"Full option text"}],"certainty":"certain"}]}"#
        let result = try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)
        XCTAssertEqual(result.questions.first?.displayAnswer, "AA. Full option text")
    }

    func testRejectsMissingNonChoiceAnswer() throws {
        let text = #"{"questions":[{"question_number":"6","opening":"Solve this equation","question_type":"other","correct_answer":"","selected_options":[],"choice_previews":[],"certainty":"certain"}]}"#
        XCTAssertThrowsError(try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)) {
            XCTAssertEqual($0 as? OpenAIExamError, .malformedStructuredOutput)
        }
    }

    func testRejectsChoiceWithoutEveryCertainOptionPreview() throws {
        let text = #"{"questions":[{"question_number":"6","opening":"Choose the correct","question_type":"multiple_choice","correct_answer":"","selected_options":["A","C"],"choice_previews":[{"label":"A","opening":"first choice"}],"certainty":"certain"}]}"#
        XCTAssertThrowsError(try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)) {
            XCTAssertEqual($0 as? OpenAIExamError, .malformedStructuredOutput)
        }
    }

    func testRejectsSingleChoiceWithTwoSelectedIdentifiers() throws {
        let text = #"{"questions":[{"question_number":"5","opening":"Choose one","question_type":"single_choice","correct_answer":"","selected_options":["1","2"],"choice_previews":[{"label":"1","opening":"First full option"},{"label":"2","opening":"Second full option"}],"certainty":"certain"}]}"#
        XCTAssertThrowsError(try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)) {
            XCTAssertEqual($0 as? OpenAIExamError, .malformedStructuredOutput)
        }
    }

    func testKeepsCompleteFillInAnswer() throws {
        let text = #"{"questions":[{"question_number":"1","opening":"100 + 100","question_type":"other","correct_answer":"200 kilograms total","selected_options":[],"choice_previews":[],"certainty":"certain"}]}"#
        let result = try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)
        XCTAssertEqual(result.questions.first?.displayAnswer, "200 kilograms total")
    }

    func testUncertainQuestionReturnsBestEffortNotificationText() throws {
        let text = #"{"questions":[{"question_number":"8","opening":"Estimate the area","question_type":"other","correct_answer":"approximately 24 cm²","selected_options":[],"choice_previews":[],"certainty":"uncertain"}]}"#
        let result = try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)
        XCTAssertEqual(
            result.questions.first?.displayAnswer,
            "不。approximately 24 cm²"
        )
    }

    func testUncertainNumericChoiceMayOmitUnreadableOptionPreview() throws {
        let text = #"{"questions":[{"question_number":"9","opening":"Choose the likely","question_type":"single_choice","correct_answer":"","selected_options":["10"],"choice_previews":[],"certainty":"uncertain"}]}"#
        let result = try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)
        XCTAssertEqual(result.questions.first?.displayAnswer, "不。10")
    }

    func testEmptyConfirmedListIsValid() throws {
        let result = try OpenAIExamAnalyzer.parseResponse(
            data: envelope(#"{"questions":[]}"#), statusCode: 200
        )
        XCTAssertTrue(result.questions.isEmpty)
    }

    func testCellularRequestUsesHTTP11() throws {
        let request = try OpenAIExamAnalyzer.makeRequest(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            apiKey: "sk-test-only", model: "gpt-6.1-sol"
        )
        let prepared = try CellularHTTPSClient.prepare(request)
        let text = try XCTUnwrap(String(data: prepared.bytes, encoding: .utf8))
        XCTAssertEqual(prepared.host, "api.openai.com")
        XCTAssertTrue(text.hasPrefix("POST /v1/responses HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Authorization: Bearer sk-test-only\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
    }

    func testRejectsAPIKeyHeaderInjection() {
        XCTAssertThrowsError(try OpenAIExamAnalyzer.makeRequest(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            apiKey: "sk-test\r\nInjected: true", model: "gpt-6.1-sol"
        )) {
            XCTAssertEqual($0 as? OpenAIExamError, .invalidAPIKey)
        }
    }

    private func envelope(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "output": [["content": [["type": "output_text", "text": text]]]]
        ])
    }
}
