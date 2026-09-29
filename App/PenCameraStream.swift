import Combine
import Foundation
@preconcurrency import Network
import UIKit

@MainActor
final class PenCameraStream: ObservableObject {
    enum StreamState: Equatable {
        case idle
        case connecting
        case handshaking(String)
        case streaming
        case reconnecting(seconds: Int, reason: String)
        case stopped
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Ready"
            case .connecting: "Connecting"
            case let .handshaking(step): step
            case .streaming: "Live"
            case let .reconnecting(seconds, _): "Reconnecting in \(seconds)s"
            case .stopped: "Stopped"
            case .failed: "Failed"
            }
        }

        var detail: String? {
            switch self {
            case let .reconnecting(_, reason), let .failed(reason): reason
            default: nil
            }
        }

        var isLive: Bool { self == .streaming }
    }

    private enum HandshakeStep: Equatable {
        case liveMotion
        case connect
        case baseInfo
        case openVideo

        var title: String {
            switch self {
            case .liveMotion: "Requesting live mode"
            case .connect: "Registering local client"
            case .baseInfo: "Reading camera information"
            case .openVideo: "Opening video stream"
            }
        }
    }

    static let cameraHost = "192.168.169.1"
    static let cameraPort: UInt16 = 6123

    @Published private(set) var state: StreamState = .idle
    @Published private(set) var latestImage: UIImage?
    @Published private(set) var latestJPEG: Data?
    @Published private(set) var frameCount = 0
    @Published private(set) var invalidJPEGCount = 0
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var firmware: String?
    @Published private(set) var lastCaptureName: String?
    @Published private(set) var captureMessage: String?

    private let networkQueue = DispatchQueue(label: "com.hongrui.pencamera.live-stream")
    private var connection: NWConnection?
    private var packetParser = NaxPacketParser()
    private var jpegAssembler = JPEGFrameAssembler()
    private var handshakeStep: HandshakeStep?
    private var wantsStreaming = false
    private var reconnectDelay = 1
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?

    var canStart: Bool {
        switch state {
        case .idle, .stopped, .failed: true
        case .connecting, .handshaking, .streaming, .reconnecting: false
        }
    }

    func startStream() {
        stopTasksAndConnection()
        wantsStreaming = true
        reconnectDelay = 1
        captureMessage = nil
        connect()
    }

    func stopStream() {
        wantsStreaming = false
        stopTasksAndConnection()
        state = .stopped
    }

    func captureLatest(jpeg requestedJPEG: Data? = nil) {
        guard let jpeg = requestedJPEG ?? latestJPEG else {
            captureMessage = "No complete JPEG frame is available yet."
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let filename = "D7WN-\(formatter.string(from: Date())).jpg"

        do {
            let directory = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try jpeg.write(to: directory.appendingPathComponent(filename), options: .atomic)
            lastCaptureName = filename
            captureMessage = "Saved the current complete frame in the app's Documents folder."
        } catch {
            captureMessage = "Capture failed: \(error.localizedDescription)"
        }
    }

    private func connect() {
        guard wantsStreaming else { return }
        guard let port = NWEndpoint.Port(rawValue: Self.cameraPort) else {
            state = .failed("Invalid TCP port")
            return
        }

        packetParser.reset()
        jpegAssembler.reset()
        handshakeStep = nil
        state = .connecting

        let connection = NWConnection(
            host: NWEndpoint.Host(Self.cameraHost),
            port: port,
            using: .tcp
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.handleConnectionState(newState, connection: connection)
            }
        }
        connection.start(queue: networkQueue)

        connectionTimeoutTask = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, let connection else { return }
            guard self.connection === connection, self.handshakeStep == nil else { return }
            self.handleTransportFailure(
                "TCP connection timed out. Confirm the iPhone is joined to Nax_5cf097da7367.",
                connection: connection
            )
        }
    }

    private func handleConnectionState(_ newState: NWConnection.State, connection: NWConnection) {
        guard self.connection === connection else { return }

        switch newState {
        case .setup, .preparing:
            state = .connecting
        case let .waiting(error):
            state = .reconnecting(seconds: reconnectDelay, reason: error.localizedDescription)
        case .ready:
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            reconnectDelay = 1
            receiveNext(on: connection)
            advance(to: .liveMotion, sending: NaxRequestFactory.liveMotion(), on: connection)
        case let .failed(error):
            handleTransportFailure(error.localizedDescription, connection: connection)
        case .cancelled:
            break
        @unknown default:
            handleTransportFailure("Unknown Network.framework state", connection: connection)
        }
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self, weak connection] data, _, isComplete, error in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.handleReceive(data, isComplete: isComplete, error: error, connection: connection)
            }
        }
    }

    private func handleReceive(
        _ data: Data?,
        isComplete: Bool,
        error: NWError?,
        connection: NWConnection
    ) {
        guard self.connection === connection else { return }

        if let data, !data.isEmpty {
            do {
                for packet in try packetParser.append(data) {
                    handlePacket(packet, connection: connection)
                    guard self.connection === connection else { return }
                }
            } catch {
                handleTransportFailure(error.localizedDescription, connection: connection)
                return
            }
        }

        if let error {
            handleTransportFailure(error.localizedDescription, connection: connection)
        } else if isComplete {
            handleTransportFailure("Camera closed the TCP stream.", connection: connection)
        } else {
            receiveNext(on: connection)
        }
    }

    private func handlePacket(_ packet: NaxPacket, connection: NWConnection) {
        if packet.command == NaxCommand.heartbeat {
            send(NaxRequestFactory.heartbeat(), on: connection)
            return
        }

        if let step = handshakeStep {
            if step == .openVideo, packet.command == NaxCommand.jpeg {
                enterStreaming()
                consumeJPEGPayload(packet.payload)
                return
            }

            captureFirmwareIfPresent(in: packet.payload)
            switch step {
            case .liveMotion:
                advance(
                    to: .connect,
                    sending: NaxRequestFactory.connect(unixTime: Int(Date().timeIntervalSince1970)),
                    on: connection
                )
            case .connect:
                advance(
                    to: .baseInfo,
                    sending: NaxRequestFactory.baseInfo(unixTime: Int(Date().timeIntervalSince1970)),
                    on: connection
                )
            case .baseInfo:
                advance(to: .openVideo, sending: NaxRequestFactory.openVideo(), on: connection)
            case .openVideo:
                enterStreaming()
            }
            return
        }

        guard state.isLive else { return }
        switch packet.command {
        case NaxCommand.jpeg:
            consumeJPEGPayload(packet.payload)
        case NaxCommand.json, NaxCommand.directMotion:
            captureFirmwareIfPresent(in: packet.payload)
        default:
            break
        }
    }

    private func advance(to step: HandshakeStep, sending packet: NaxPacket, on connection: NWConnection) {
        handshakeStep = step
        state = .handshaking(step.title)
        armHandshakeTimeout(for: step, connection: connection)
        send(packet, on: connection)
    }

    private func enterStreaming() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        handshakeStep = nil
        reconnectDelay = 1
        state = .streaming
        startHeartbeat()
    }

    private func send(_ packet: NaxPacket, on connection: NWConnection) {
        connection.send(content: packet.encoded(), completion: .contentProcessed { [weak self, weak connection] error in
            guard let error, let connection else { return }
            Task { @MainActor [weak self] in
                self?.handleTransportFailure(error.localizedDescription, connection: connection)
            }
        })
    }

    private func consumeJPEGPayload(_ payload: Data) {
        let previousDroppedCount = jpegAssembler.droppedFrameCount
        let frames = jpegAssembler.append(payload)
        invalidJPEGCount += jpegAssembler.droppedFrameCount - previousDroppedCount

        for jpeg in frames {
            guard let image = UIImage(data: jpeg) else {
                invalidJPEGCount += 1
                continue
            }
            latestJPEG = jpeg
            latestImage = image
            frameCount += 1
            lastFrameAt = Date()
        }
    }

    private func captureFirmwareIfPresent(in payload: Data) {
        guard
            !payload.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: payload),
            let value = findFirmware(in: object)
        else { return }
        firmware = value
    }

    private func findFirmware(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["version", "firmware", "firmwareVersion", "softVersion"] {
                if let value = dictionary[key] as? String { return value }
                if let value = dictionary[key] as? NSNumber { return value.stringValue }
            }
            for value in dictionary.values {
                if let result = findFirmware(in: value) { return result }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let result = findFirmware(in: value) { return result }
            }
        }
        return nil
    }

    private func armHandshakeTimeout(for step: HandshakeStep, connection: NWConnection) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let connection else { return }
            guard self.connection === connection, self.handshakeStep == step else { return }
            self.handleTransportFailure("Timed out while \(step.title.lowercased()).", connection: connection)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, let connection = self.connection, self.state.isLive else { return }
                self.send(NaxRequestFactory.heartbeat(), on: connection)
            }
        }
    }

    private func handleTransportFailure(_ reason: String, connection: NWConnection) {
        guard self.connection === connection else { return }
        teardown(connection)

        guard wantsStreaming else {
            state = .stopped
            return
        }

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 8)
        state = .reconnecting(seconds: delay, reason: reason)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantsStreaming else { return }
            self.connect()
        }
    }

    private func teardown(_ connection: NWConnection) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        handshakeStep = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        if self.connection === connection {
            self.connection = nil
        }
    }

    private func stopTasksAndConnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        handshakeStep = nil
        if let connection {
            teardown(connection)
        }
    }
}
