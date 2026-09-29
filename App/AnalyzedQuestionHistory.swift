import Foundation

struct SeenQuestionRecord: Codable, Equatable, Sendable {
    let questionNumber: String
    let normalizedText: String
}

@MainActor
final class AnalyzedQuestionHistory {
    private static let storageKey = "continuous-analysis-seen-questions-v1"
    private static let maximumRecordCount = 500

    private let defaults: UserDefaults
    private var records: [SeenQuestionRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SeenQuestionRecord].self, from: data) {
            records = Array(decoded.suffix(Self.maximumRecordCount))
        } else {
            records = []
        }
    }

    var count: Int { records.count }

    func contains(_ question: ExamQuestionResult) -> Bool {
        let candidate = Self.record(for: question)
        return records.contains { stored in
            guard stored.questionNumber == candidate.questionNumber else { return false }
            if stored.normalizedText == candidate.normalizedText { return true }
            return Self.diceSimilarity(stored.normalizedText, candidate.normalizedText) >= 0.88
        }
    }

    func insert(_ question: ExamQuestionResult) {
        guard !contains(question) else { return }
        records.append(Self.record(for: question))
        if records.count > Self.maximumRecordCount {
            records.removeFirst(records.count - Self.maximumRecordCount)
        }
        persist()
    }

    func clear() {
        records.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "+-×÷=<>≤≥√π%/^()")
        )
        let scalars = folded.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    static func diceSimilarity(_ first: String, _ second: String) -> Double {
        guard !first.isEmpty, !second.isEmpty else {
            return first == second ? 1 : 0
        }
        if first == second { return 1 }

        let firstPairs = bigrams(first)
        let secondPairs = bigrams(second)
        guard !firstPairs.isEmpty, !secondPairs.isEmpty else { return 0 }
        let overlap = firstPairs.intersection(secondPairs).count
        return Double(2 * overlap) / Double(firstPairs.count + secondPairs.count)
    }

    private static func record(for question: ExamQuestionResult) -> SeenQuestionRecord {
        SeenQuestionRecord(
            questionNumber: normalize(question.questionNumber),
            normalizedText: normalize(question.questionText)
        )
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= 2 else { return [text] }
        return Set((0..<(characters.count - 1)).map { index in
            String(characters[index...(index + 1)])
        })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
