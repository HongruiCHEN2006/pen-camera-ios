import Combine
import Foundation
@preconcurrency import Network

@MainActor
final class CameraConnectionTester: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case waiting(String)
        case succeeded(interface: String, latencyMilliseconds: Int)
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "Not tested"
            case .connecting:
                return "Connecting…"
            case .waiting:
                return "Waiting for route…"
            case .succeeded:
                return "TCP connection succeeded"
            case .failed:
                return "TCP connection failed"
            }
        }

        var detail: String? {
            switch self {
            case let .waiting(message), let .failed(message):
                return message
            case let .succeeded(interface, latencyMilliseconds):
                return "Interface: \(interface) · \(latencyMilliseconds) ms"
            case .idle, .connecting:
                return nil
            }
        }
    }

    static let cameraHost = "192.168.169.1"
    static let cameraPort: UInt16 = 6123

    @Published private(set) var phase: Phase = .idle

    private var connection: NWConnection?
    private var timeoutTask: Task<Void, Never>?
    private var startedAt: Date?

    var isRunning: Bool {
        switch phase {
        case .connecting, .waiting:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    func testConnection() {
        cancelCurrentProbe()

        guard let port = NWEndpoint.Port(rawValue: Self.cameraPort) else {
            phase = .failed("Invalid TCP port")
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(Self.cameraHost),
            port: port,
            using: .tcp
        )

        self.connection = connection
        startedAt = Date()
        phase = .connecting

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.handle(state, for: connection)
            }
        }

        connection.start(queue: DispatchQueue(label: "com.hongrui.pencamera.tcp-probe"))

        timeoutTask = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, let connection else { return }
            guard self.connection === connection else { return }
            self.finish(
                with: .failed("Timed out after 8 seconds. Confirm the iPhone is joined to Nax_5cf097da7367 and Local Network access is allowed."),
                connection: connection
            )
        }
    }

    private func handle(_ state: NWConnection.State, for connection: NWConnection) {
        guard self.connection === connection else { return }

        switch state {
        case .setup, .preparing:
            phase = .connecting
        case let .waiting(error):
            phase = .waiting(error.localizedDescription)
        case .ready:
            let interface = interfaceDescription(for: connection.currentPath)
            let elapsed = Date().timeIntervalSince(startedAt ?? Date())
            let latency = max(0, Int((elapsed * 1_000).rounded()))
            finish(
                with: .succeeded(interface: interface, latencyMilliseconds: latency),
                connection: connection
            )
        case let .failed(error):
            finish(with: .failed(error.localizedDescription), connection: connection)
        case .cancelled:
            break
        @unknown default:
            finish(with: .failed("Unknown Network.framework state"), connection: connection)
        }
    }

    private func interfaceDescription(for path: NWPath?) -> String {
        guard let path else { return "Unknown" }
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.cellular) { return "Cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "Ethernet" }
        if path.usesInterfaceType(.loopback) { return "Loopback" }
        return "Other"
    }

    private func finish(with phase: Phase, connection: NWConnection) {
        guard self.connection === connection else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        startedAt = nil
        self.phase = phase
    }

    private func cancelCurrentProbe() {
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        startedAt = nil
    }
}

