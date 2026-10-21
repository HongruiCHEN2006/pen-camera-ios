import Foundation
import UserNotifications

@MainActor
final class QuestionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = QuestionNotificationService()

    private let center: UNUserNotificationCenter

    private override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async throws -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .ephemeral, .provisional:
            return true
        case .notDetermined:
            return try await center.requestAuthorization(options: [.alert, .sound])
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func notify(question: ExamQuestionResult, sequence: Int) async throws {
        let content = UNMutableNotificationContent()
        content.title = "\(question.questionNumber)：\(brief(question.opening))"
        content.body = "答案：\(question.displayAnswer)"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(max(1, sequence)),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "question-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    private func brief(_ text: String) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > 42 else { return clean }
        return String(clean.prefix(42)) + "…"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
