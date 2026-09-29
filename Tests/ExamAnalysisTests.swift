import Foundation
import XCTest
@testable import PenCamera

final class ExamAnalysisTests: XCTestCase {
    func testRoutePoliciesRequireSeparateInterfaces() {
        XCTAssertEqual(
            NetworkRoutePolicy.cameraWiFiParameters().requiredInterfaceType,
            .wifi
        )
        XCTAssertEqual(
            NetworkRoutePolicy.cloudCellularParameters().requiredInterfaceType,
            .cellular
        )
    }

    func testRequestUsesResponsesVisionStructuredOutputAndDoesNotStoreResponse() throws {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let request = try OpenAIExamAnalyzer.makeRequest(
            jpeg: jpeg,
            apiKey: "sk-test-only",
            model: "gpt-4o-mini"
        )

        XCTAssertEqual(request.url, OpenAIExamAnalyzer.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-only")

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(object["store"] as? Bool, false)

        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.first(where: { $0["type"] as? String == "input_image" }))
        XCTAssertEqual(image["detail"] as? String, "high")
        XCTAssertEqual(
            image["image_url"] as? String,
            "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        )

        let text = try XCTUnwrap(object["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let readSuccess = try XCTUnwrap(properties["read_success"] as? [String: Any])
        XCTAssertEqual(readSuccess["enum"] as? [String], ["是", "否"])
        let questions = try XCTUnwrap(properties["questions"] as? [String: Any])
        XCTAssertEqual(questions["type"] as? String, "array")
        let items = try XCTUnwrap(questions["items"] as? [String: Any])
        XCTAssertEqual(items["additionalProperties"] as? Bool, false)
        XCTAssertEqual(
            items["required"] as? [String],
            ["question_number", "is_complete", "question_text", "answer"]
        )
    }

    func testParsesSuccessfulAnswerResult() throws {
        let structuredResult = """
        {"read_success":"是","questions":[{"question_number":"12","is_complete":true,"question_text":"Which value is correct? A. 1 B. 2","answer":"B"}]}
        """
        let envelope: [String: Any] = [
            "output": [
                [
                    "type": "message",
                    "content": [
                        ["type": "output_text", "text": structuredResult]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let result = try OpenAIExamAnalyzer.parseResponse(data: data, statusCode: 200)

        XCTAssertEqual(result.readSuccess, .yes)
        XCTAssertEqual(result.completeQuestions.count, 1)
        XCTAssertEqual(result.completeQuestions.first?.questionNumber, "12")
        XCTAssertEqual(result.completeQuestions.first?.answer, "B")
    }

    func testParsesUnreadableResultWithEmptyAnswer() throws {
        let structuredResult = #"{"read_success":"否","questions":[]}"#
        let envelope: [String: Any] = [
            "output": [
                [
                    "type": "message",
                    "content": [
                        ["type": "output_text", "text": structuredResult]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let result = try OpenAIExamAnalyzer.parseResponse(data: data, statusCode: 200)

        XCTAssertEqual(result.readSuccess, .no)
        XCTAssertTrue(result.questions.isEmpty)
    }

    func testRejectsSuccessfulReadWithoutAnswer() throws {
        let envelope: [String: Any] = [
            "output": [
                [
                    "content": [
                        ["type": "output_text", "text": #"{"read_success":"是","questions":[{"question_number":"8","is_complete":true,"question_text":"8. 1 + 1 = ?","answer":""}]}"#]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        XCTAssertThrowsError(try OpenAIExamAnalyzer.parseResponse(data: data, statusCode: 200)) { error in
            XCTAssertEqual(error as? OpenAIExamError, .malformedStructuredOutput)
        }
    }

    func testParsesIncompleteQuestionOnlyWithEmptyAnswer() throws {
        let structuredResult = #"{"read_success":"否","questions":[{"question_number":"9","is_complete":false,"question_text":"9. The cropped question begins","answer":""}]}"#
        let envelope: [String: Any] = [
            "output": [
                [
                    "content": [
                        ["type": "output_text", "text": structuredResult]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let result = try OpenAIExamAnalyzer.parseResponse(data: data, statusCode: 200)

        XCTAssertEqual(result.readSuccess, .no)
        XCTAssertEqual(result.questions.count, 1)
        XCTAssertFalse(result.questions[0].isComplete)
    }

    func testRejectsNoReadStatusWhenCompleteQuestionExists() throws {
        let structuredResult = #"{"read_success":"否","questions":[{"question_number":"4","is_complete":true,"question_text":"4. 2 + 2 = ?","answer":"4"}]}"#
        let envelope: [String: Any] = [
            "output": [
                [
                    "content": [
                        ["type": "output_text", "text": structuredResult]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        XCTAssertThrowsError(try OpenAIExamAnalyzer.parseResponse(data: data, statusCode: 200)) { error in
            XCTAssertEqual(error as? OpenAIExamError, .malformedStructuredOutput)
        }
    }

    func testParsesOpenAIErrorMessageWithoutLeakingRequestKey() throws {
        let data = Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
        XCTAssertThrowsError(try OpenAIExamAnalyzer.parseResponse(data: data, statusCode: 401)) { error in
            XCTAssertEqual(
                error as? OpenAIExamError,
                .api(statusCode: 401, message: "Invalid API key")
            )
        }
    }

    func testRejectsNonSchemaOutput() throws {
        let envelope: [String: Any] = [
            "output": [
                [
                    "content": [
                        ["type": "output_text", "text": #"{"read_success":"yes","questions":[]}"#]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try OpenAIExamAnalyzer.parseResponse(data: data, statusCode: 200)) { error in
            XCTAssertEqual(error as? OpenAIExamError, .malformedStructuredOutput)
        }
    }

    func testCellularHTTPPreparationPreservesOpenAIRequestAndUsesHTTP11() throws {
        let request = try OpenAIExamAnalyzer.makeRequest(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            apiKey: "sk-test-only",
            model: "gpt-4o-mini"
        )

        let prepared = try CellularHTTPSClient.prepare(request)
        let text = try XCTUnwrap(String(data: prepared.bytes, encoding: .utf8))
        XCTAssertEqual(prepared.host, "api.openai.com")
        XCTAssertEqual(prepared.port, 443)
        XCTAssertTrue(text.hasPrefix("POST /v1/responses HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: api.openai.com\r\n"))
        XCTAssertTrue(text.contains("Authorization: Bearer sk-test-only\r\n"))
        XCTAssertTrue(text.contains("Accept-Encoding: identity\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
    }

    func testRequestRejectsHeaderInjectionInAPIKey() {
        XCTAssertThrowsError(
            try OpenAIExamAnalyzer.makeRequest(
                jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                apiKey: "sk-test\r\nInjected: true",
                model: "gpt-4o-mini"
            )
        ) { error in
            XCTAssertEqual(error as? OpenAIExamError, .invalidAPIKey)
        }
    }

    func testParsesIncrementalContentLengthResponse() throws {
        var parser = CellularHTTPResponseParser(maximumBytes: 1_024)
        try parser.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhe".utf8))
        XCTAssertNil(try parser.responseIfComplete(connectionComplete: false))
        try parser.append(Data("llo".utf8))

        let response = try XCTUnwrap(parser.responseIfComplete(connectionComplete: false))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("hello".utf8))
    }

    func testParsesChunkedResponse() throws {
        var parser = CellularHTTPResponseParser(maximumBytes: 1_024)
        let responseBytes = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
        try parser.append(Data(responseBytes.utf8))

        let response = try XCTUnwrap(parser.responseIfComplete(connectionComplete: false))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("Wikipedia".utf8))
    }
}
