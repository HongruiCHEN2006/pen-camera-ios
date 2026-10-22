import Foundation
@preconcurrency import Network

struct GlassesQuestionPayload: Codable, Equatable, Sendable {
    let sequence: Int
    let batchID: String
    let batchIndex: Int
    let batchTotal: Int
    let questionNumber: String
    let question: String
    let answer: String
    let certainty: String
    let receivedAt: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case batchID = "batch_id"
        case batchIndex = "batch_index"
        case batchTotal = "batch_total"
        case questionNumber = "question_number"
        case question, answer, certainty
        case receivedAt = "received_at"
    }
}

struct GlassesQuestionEnvelope: Codable, Equatable, Sendable {
    let sessionID: String
    let latestSequence: Int
    let camera: GlassesCameraStatusPayload
    let questions: [GlassesQuestionPayload]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case latestSequence = "latest_sequence"
        case camera
        case questions
    }
}

struct GlassesCameraStatusPayload: Codable, Equatable, Sendable {
    let connected: Bool
    let state: String
    let batteryLevel: Int?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case connected, state
        case batteryLevel = "battery_level"
        case updatedAt = "updated_at"
    }
}

enum GlassesRelayError: LocalizedError, Equatable {
    case invalidPort
    case listener(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort: "The Even G2 relay port is invalid."
        case let .listener(message): "The Even G2 relay could not start: \(message)"
        }
    }
}

final class GlassesRelayServer: @unchecked Sendable {
    static let shared = GlassesRelayServer()
    static let portNumber: UInt16 = 8765
    static let endpointDescription = "http://127.0.0.1:\(portNumber)"

    private let queue = DispatchQueue(label: "com.hongrui.pencamera.even-g2-relay")
    private let lock = NSLock()
    private var listener: NWListener?
    private let sessionID = UUID().uuidString
    private var questions: [GlassesQuestionPayload] = []
    private var nextSequence = 1
    private var cameraStatus = GlassesCameraStatusPayload(
        connected: false,
        state: "disconnected",
        batteryLevel: nil,
        updatedAt: ISO8601DateFormatter().string(from: Date())
    )
    private let encoder: JSONEncoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: Self.portNumber) else {
            throw GlassesRelayError.invalidPort
        }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"), port: port
            )
            let newListener = try NWListener(using: parameters)
            newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            newListener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NSLog("Even G2 relay failed: %@", error.localizedDescription)
                }
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            listener = nil
            throw GlassesRelayError.listener(error.localizedDescription)
        }
    }

    @discardableResult
    func publish(question: ExamQuestionResult, receivedAt: Date = Date()) -> GlassesQuestionPayload {
        publishBatch([question], receivedAt: receivedAt)[0]
    }

    @discardableResult
    func publishBatch(
        _ batch: [ExamQuestionResult], receivedAt: Date = Date()
    ) -> [GlassesQuestionPayload] {
        lock.lock()
        defer { lock.unlock() }
        let batchID = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: receivedAt)
        let payloads = batch.enumerated().map { index, question in
            GlassesQuestionPayload(
                sequence: nextSequence + index,
                batchID: batchID,
                batchIndex: index + 1,
                batchTotal: batch.count,
                questionNumber: question.questionNumber,
                question: question.opening,
                answer: question.displayAnswer,
                certainty: question.certainty,
                receivedAt: timestamp
            )
        }
        nextSequence += payloads.count
        questions.append(contentsOf: payloads)
        if questions.count > 100 { questions.removeFirst(questions.count - 100) }
        return payloads
    }

    func snapshot(after sequence: Int) -> GlassesQuestionEnvelope {
        lock.withLock {
            GlassesQuestionEnvelope(
                sessionID: sessionID,
                latestSequence: nextSequence - 1,
                camera: cameraStatus,
                questions: questions.filter { $0.sequence > sequence }
            )
        }
    }

    func updateCameraStatus(connected: Bool, state: String, batteryLevel: Int?) {
        lock.withLock {
            cameraStatus = GlassesCameraStatusPayload(
                connected: connected,
                state: state,
                batteryLevel: batteryLevel,
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            guard error == nil, let data, !data.isEmpty,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let requestLine = request.split(separator: "\n", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else {
            send(status: "400 Bad Request", body: Data(), on: connection)
            return
        }
        let method = String(components[0])
        if method == "OPTIONS" {
            send(status: "204 No Content", body: Data(), on: connection)
            return
        }
        guard method == "GET" else {
            send(status: "405 Method Not Allowed", body: Data(), on: connection)
            return
        }

        let target = String(components[1])
        guard let url = URL(string: "http://localhost\(target)"),
              url.path == "/api/questions" else {
            send(status: "404 Not Found", body: Data(), on: connection)
            return
        }
        let after = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "after" })?.value
            .flatMap(Int.init) ?? 0
        do {
            send(status: "200 OK", body: try encoder.encode(snapshot(after: max(0, after))), on: connection)
        } catch {
            send(status: "500 Internal Server Error", body: Data(), on: connection)
        }
    }

    private func send(status: String, body: Data, on connection: NWConnection) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
