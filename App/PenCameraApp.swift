import SwiftUI

@main
struct PenCameraApp: App {
    init() {
        BackgroundCaptureCoordinator.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
