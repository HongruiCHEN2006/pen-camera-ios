import Foundation
import XCTest
@testable import PenCamera

final class ExamAnalysisTests: XCTestCase {
    func testRoutePoliciesRequireSeparateInterfaces() {
        XCTAssertEqual(NetworkRoutePolicy.cameraWiFiParameters().requiredInterfaceType, .wifi)
        XCTAssertEqual(NetworkRoutePolicy.cloudCellularParameters().requiredInterfaceType, .cellular)
    }

    func testBatchRequestUsesLunaLowReasoningAndHighDetailForEachImage() throws {
        let images = [Data([0xFF, 0xD8, 1, 0xFF, 0xD9]), Data([0xFF, 0xD8, 2, 0xFF, 0xD9])]
        let request = try OpenAIExamAnalyzer.makeRequest(
            jpegs: images, apiKey: "sk-test-only", model: OpenAIExamAnalyzer.defaultModel
        )
        XCTAssertEqual(request.url, OpenAIExamAnalyzer.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-only")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(object["store"] as? Bool, false)
        let reasoning = try XCTUnwrap(object["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "low")
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
            "question_number", "opening", "answer", "is_multiple_choice", "option_letter", "option_opening"
        ])
        let prompt = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(prompt.contains("first TWO words"))
        XCTAssertTrue(prompt.contains("only ONE word, report that one word"))
    }

    func testParsesConfirmedQuestionsAndRemovesDuplicatesWithinBatch() throws {
        let text = #"{"questions":[{"question_number":"2","opening":"Find the value","answer":"","is_multiple_choice":true,"option_letter":"b","option_opening":"cell membrane"},{"question_number":"x","opening":"求图中阴影面积","answer":"24","is_multiple_choice":false,"option_letter":"","option_opening":""},{"question_number":"2","opening":"Find the value","answer":"","is_multiple_choice":true,"option_letter":"B","option_opening":"cell membrane"}]}"#
        let result = try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)
        XCTAssertEqual(result.questions.count, 2)
        XCTAssertEqual(result.questions[0].questionNumber, "2")
        XCTAssertEqual(result.questions[0].displayAnswer, "B：cell membrane")
        XCTAssertEqual(result.questions[1].questionNumber, "x")
        XCTAssertEqual(result.questions[1].opening, "求图中阴影面积")
    }

    func testRejectsMissingAnswer() throws {
        let text = #"{"questions":[{"question_number":"6","opening":"Solve this equation","answer":"","is_multiple_choice":false,"option_letter":"","option_opening":""}]}"#
        XCTAssertThrowsError(try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)) {
            XCTAssertEqual($0 as? OpenAIExamError, .malformedStructuredOutput)
        }
    }

    func testRejectsChoiceWithoutOptionOpening() throws {
        let text = #"{"questions":[{"question_number":"6","opening":"Choose the correct","answer":"","is_multiple_choice":true,"option_letter":"C","option_opening":""}]}"#
        XCTAssertThrowsError(try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)) {
            XCTAssertEqual($0 as? OpenAIExamError, .malformedStructuredOutput)
        }
    }

    func testAcceptsOneWordChoice() throws {
        let text = #"{"questions":[{"question_number":"4","opening":"Which animal flies","answer":"","is_multiple_choice":true,"option_letter":"A","option_opening":"Bird"}]}"#
        let result = try OpenAIExamAnalyzer.parseResponse(data: envelope(text), statusCode: 200)
        XCTAssertEqual(result.questions.first?.displayAnswer, "A：Bird")
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
            apiKey: "sk-test-only", model: "gpt-5.6-luna"
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
            apiKey: "sk-test\r\nInjected: true", model: "gpt-5.6-luna"
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
