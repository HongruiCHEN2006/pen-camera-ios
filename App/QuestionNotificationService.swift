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
        case .authorized, .provisional, .ephemeral:
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
        content.title = "题目 \(question.questionNumber)"
        content.body = "答案：\(question.answer)"
        content.sound = .default

        let delay = max(1, sequence)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(delay),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "question-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
