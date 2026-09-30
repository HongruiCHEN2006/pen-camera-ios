import BackgroundTasks
import Combine
import Foundation

@MainActor
final class BackgroundCaptureCoordinator: ObservableObject {
    static let shared = BackgroundCaptureCoordinator()
    static let taskIdentifier = "com.hongrui.pencamera.capture"

    @Published private(set) var status = "Not requested"
    var isInBackground = false

    private var registered = false
    private var task: BGContinuedProcessingTask?
    private var sessionIsPending = false
    private var onExpiration: (() -> Void)?

    private init() {}

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier, using: nil
        ) { [weak self] launchedTask in
            Task { @MainActor [weak self] in
                self?.accept(launchedTask)
            }
        }
        if !registered { status = "iOS background task registration failed" }
    }

    func start(onExpiration: @escaping () -> Void) {
        guard registered else {
            status = "Unavailable; foreground capture only"
            return
        }
        guard !sessionIsPending, task == nil else { return }
        self.onExpiration = onExpiration
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: "Pen Camera capture",
            subtitle: "Collecting frames until the camera goes black"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            sessionIsPending = true
            status = "Requested; awaiting iOS confirmation"
        } catch {
            self.onExpiration = nil
            status = "Unavailable: \(error.localizedDescription)"
        }
    }

    func reportProgress(imageCount: Int, uploading: Bool) {
        guard let task else { return }
        task.progress.totalUnitCount = Int64(CameraBatchCapture.maximumFrames + 1)
        task.progress.completedUnitCount = Int64(min(imageCount, CameraBatchCapture.maximumFrames))
        task.updateTitle(
            "Pen Camera capture",
            subtitle: uploading ? "Uploading and analyzing" : "Saved \(imageCount) frame(s)"
        )
    }

    func finish(success: Bool) {
        sessionIsPending = false
        onExpiration = nil
        if let task {
            task.expirationHandler = nil
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
            self.task = nil
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        }
        status = success ? "Batch finished; background task ended" : "Capture stopped"
    }

    private func accept(_ launchedTask: BGTask) {
        guard let launchedTask = launchedTask as? BGContinuedProcessingTask else {
            launchedTask.setTaskCompleted(success: false)
            return
        }
        guard sessionIsPending else {
            launchedTask.setTaskCompleted(success: false)
            return
        }
        task = launchedTask
        launchedTask.progress.totalUnitCount = Int64(CameraBatchCapture.maximumFrames + 1)
        status = "Active (iOS may end it)"
        launchedTask.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = "Ended by iOS; capture stopped"
                self.onExpiration?()
                self.finish(success: false)
                self.status = "Ended by iOS; capture stopped"
            }
        }
    }
}
