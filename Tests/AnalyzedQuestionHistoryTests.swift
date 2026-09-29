import Foundation
import XCTest
@testable import PenCamera

@MainActor
final class AnalyzedQuestionHistoryTests: XCTestCase {
    func testSameQuestionWithFormattingDifferencesIsRemembered() {
        let defaults = makeDefaults()
        let history = AnalyzedQuestionHistory(defaults: defaults)
        let original = question(number: "12.", text: "What is 2 + 2? A. 3  B. 4")
        let repeated = question(number: "12", text: "What is 2+2？ A、3 B、4")

        history.insert(original)

        XCTAssertTrue(history.contains(repeated))
        XCTAssertEqual(history.count, 1)
    }

    func testSameNumberWithDifferentQuestionIsNotRemembered() {
        let defaults = makeDefaults()
        let history = AnalyzedQuestionHistory(defaults: defaults)
        history.insert(question(number: "7", text: "Which planet is closest to the Sun?"))

        XCTAssertFalse(
            history.contains(question(number: "7", text: "What is the capital of France?"))
        )
    }

    func testHistoryPersistsAndCanBeCleared() {
        let defaults = makeDefaults()
        let item = question(number: "3", text: "Solve x + 1 = 4")
        AnalyzedQuestionHistory(defaults: defaults).insert(item)

        let reloaded = AnalyzedQuestionHistory(defaults: defaults)
        XCTAssertTrue(reloaded.contains(item))
        reloaded.clear()

        XCTAssertEqual(AnalyzedQuestionHistory(defaults: defaults).count, 0)
    }

    private func question(number: String, text: String) -> ExamQuestionResult {
        ExamQuestionResult(
            questionNumber: number,
            isComplete: true,
            questionText: text,
            answer: "test answer"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AnalyzedQuestionHistoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
