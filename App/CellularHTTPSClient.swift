import Foundation
@preconcurrency import Network

struct CellularHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let body: Data
}

enum CellularHTTPError: LocalizedError, Equatable {
    case invalidRequest
    case cellularUnavailable(String)
    case routeWasNotCellular
    case connectionFailed(String)
    case timedOut
    case responseTooLarge
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The OpenAI HTTPS request could not be created."
        case let .cellularUnavailable(detail):
            "Cellular data is unavailable. Wi-Fi fallback is disabled. \(detail)"
        case .routeWasNotCellular:
            "The cloud connection was not cellular, so the request was blocked."
        case let .connectionFailed(detail):
            "The cellular cloud connection failed: \(detail)"
        case .timedOut:
            "The cellular cloud connection timed out."
        case .responseTooLarge:
            "The cloud response exceeded the app's safety limit."
        case let .invalidResponse(detail):
            "The cloud returned an invalid HTTP response: \(detail)"
        }
    }
}

struct CellularHTTPSClient: Sendable {
    struct PreparedRequest: Sendable {
        let host: String
        let port: UInt16
        let bytes: Data
    }

    let timeout: TimeInterval
    let maximumResponseBytes: Int

    init(timeout: TimeInterval = 90, maximumResponseBytes: Int = 8 * 1_024 * 1_024) {
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    func send(_ request: URLRequest) async throws -> CellularHTTPResponse {
        let prepared = try Self.prepare(request)
        let operation = CellularHTTPRequestOperation(
            request: prepared,
            timeout: timeout,
            maximumResponseBytes: maximumResponseBytes
        )
        return try await operation.run()
    }

    static func prepare(_ request: URLRequest) throws -> PreparedRequest {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              let method = request.httpMethod?.uppercased(),
              !method.isEmpty,
              !method.contains("\r"),
              !method.contains("\n") else {
            throw CellularHTTPError.invalidRequest
        }

        let resolvedPort = url.port ?? 443
        guard let port = UInt16(exactly: resolvedPort) else {
            throw CellularHTTPError.invalidRequest
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? url.path
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            target += "?\(query)"
        }
        guard !target.contains("\r"), !target.contains("\n"), !target.contains(" ") else {
            throw CellularHTTPError.invalidRequest
        }

        let body = request.httpBody ?? Data()
        let excludedHeaders = Set(["host", "content-length", "connection", "accept-encoding"])
        var headers: [(String, String)] = []
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            guard !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else {
                throw CellularHTTPError.invalidRequest
            }
            if !excludedHeaders.contains(name.lowercased()) {
                headers.append((name, value))
            }
        }

        if !headers.contains(where: { $0.0.caseInsensitiveCompare("Accept") == .orderedSame }) {
            headers.append(("Accept", "application/json"))
        }
        headers.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        let hostHeader = resolvedPort == 443 ? host : "\(host):\(resolvedPort)"
        var head = "\(method) \(target) HTTP/1.1\r\n"
        head += "Host: \(hostHeader)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Accept-Encoding: identity\r\n"
        head += "Connection: close\r\n"
        head += "Content-Length: \(body.count)\r\n\r\n"

        guard let headData = head.data(using: .utf8) else {
            throw CellularHTTPError.invalidRequest
        }
        var bytes = Data(capacity: headData.count + body.count)
        bytes.append(headData)
        bytes.append(body)
        return PreparedRequest(host: host, port: port, bytes: bytes)
    }
}

private final class CellularHTTPRequestOperation: @unchecked Sendable {
    private let request: CellularHTTPSClient.PreparedRequest
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.hongrui.pencamera.cellular-https")
    private var parser: CellularHTTPResponseParser
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<CellularHTTPResponse, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var terminalErrorBeforeStart: Error?
    private var hasSentRequest = false
    private var isFinished = false

    init(
        request: CellularHTTPSClient.PreparedRequest,
        timeout: TimeInterval,
        maximumResponseBytes: Int
    ) {
        self.request = request
        self.timeout = timeout
        parser = CellularHTTPResponseParser(maximumBytes: maximumResponseBytes)
    }

    func run() async throws -> CellularHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    begin(continuation)
                }
            }
        } onCancel: {
            self.queue.async { [self] in
                cancel()
            }
        }
    }

    private func begin(_ continuation: CheckedContinuation<CellularHTTPResponse, Error>) {
        if let terminalErrorBeforeStart {
            continuation.resume(throwing: terminalErrorBeforeStart)
            return
        }

        self.continuation = continuation
        guard let port = NWEndpoint.Port(rawValue: request.port) else {
            finish(.failure(CellularHTTPError.invalidRequest))
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(request.host),
            port: port,
            using: NetworkRoutePolicy.cloudCellularParameters()
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.start(queue: queue)

        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(CellularHTTPError.timedOut))
        }
        timeoutWorkItem = timeoutItem
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    }

    private func handle(_ state: NWConnection.State) {
        guard !isFinished, let connection else { return }

        switch state {
        case .setup, .preparing:
            break
        case let .waiting(error):
            finish(.failure(CellularHTTPError.cellularUnavailable(error.localizedDescription)))
        case .ready:
            guard connection.currentPath?.usesInterfaceType(.cellular) == true else {
                finish(.failure(CellularHTTPError.routeWasNotCellular))
                return
            }
            sendRequest(on: connection)
        case let .failed(error):
            finish(.failure(CellularHTTPError.connectionFailed(error.localizedDescription)))
        case .cancelled:
            if !isFinished {
                finish(.failure(CellularHTTPError.connectionFailed("The connection was cancelled.")))
            }
        @unknown default:
            finish(.failure(CellularHTTPError.connectionFailed("Unknown Network.framework state.")))
        }
    }

    private func sendRequest(on connection: NWConnection) {
        guard !hasSentRequest else { return }
        hasSentRequest = true
        connection.send(content: request.bytes, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(CellularHTTPError.connectionFailed(error.localizedDescription)))
            } else {
                self.receiveNext(on: connection)
            }
        })
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }

            do {
                if let data, !data.isEmpty {
                    try self.parser.append(data)
                }
                if let response = try self.parser.responseIfComplete(connectionComplete: isComplete) {
                    self.finish(.success(response))
                    return
                }
            } catch {
                self.finish(.failure(error))
                return
            }

            if let error {
                self.finish(.failure(CellularHTTPError.connectionFailed(error.localizedDescription)))
            } else if isComplete {
                self.finish(.failure(CellularHTTPError.invalidResponse("The server closed the connection before the response completed.")))
            } else {
                self.receiveNext(on: connection)
            }
        }
    }

    private func cancel() {
        guard continuation != nil else {
            terminalErrorBeforeStart = CancellationError()
            return
        }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<CellularHTTPResponse, Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

struct CellularHTTPResponseParser {
    private static let headerSeparator = Data([13, 10, 13, 10])
    private static let lineSeparator = Data([13, 10])

    private let maximumBytes: Int
    private var buffer = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ data: Data) throws {
        guard data.count <= maximumBytes,
              buffer.count <= maximumBytes - data.count else {
            throw CellularHTTPError.responseTooLarge
        }
        buffer.append(data)
    }

    mutating func responseIfComplete(connectionComplete: Bool) throws -> CellularHTTPResponse? {
        guard let separatorRange = buffer.range(of: Self.headerSeparator) else {
            if connectionComplete {
                throw CellularHTTPError.invalidResponse("Missing HTTP headers.")
            }
            return nil
        }

        let headerData = buffer[..<separatorRange.lowerBound]
        guard let headerText = String(data: Data(headerData), encoding: .isoLatin1) else {
            throw CellularHTTPError.invalidResponse("Headers are not valid ISO-8859-1 text.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw CellularHTTPError.invalidResponse("Missing status line.")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusParts[1]) else {
            throw CellularHTTPError.invalidResponse("Invalid status line.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw CellularHTTPError.invalidResponse("Malformed header line.")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + "," + value
            } else {
                headers[name] = value
            }
        }

        let body = Data(buffer[separatorRange.upperBound...])
        if statusCode == 204 || statusCode == 304 || (100..<200).contains(statusCode) {
            return CellularHTTPResponse(statusCode: statusCode, body: Data())
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = try Self.decodeChunked(body) else {
                if connectionComplete {
                    throw CellularHTTPError.invalidResponse("Incomplete chunked body.")
                }
                return nil
            }
            return CellularHTTPResponse(statusCode: statusCode, body: decoded)
        }

        if let contentLengthText = headers["content-length"] {
            guard let contentLength = Int(contentLengthText), contentLength >= 0 else {
                throw CellularHTTPError.invalidResponse("Invalid Content-Length.")
            }
            guard contentLength <= maximumBytes else {
                throw CellularHTTPError.responseTooLarge
            }
            guard body.count >= contentLength else {
                if connectionComplete {
                    throw CellularHTTPError.invalidResponse("Incomplete response body.")
                }
                return nil
            }
            return CellularHTTPResponse(statusCode: statusCode, body: Data(body.prefix(contentLength)))
        }

        guard connectionComplete else { return nil }
        return CellularHTTPResponse(statusCode: statusCode, body: body)
    }

    private static func decodeChunked(_ data: Data) throws -> Data? {
        var cursor = data.startIndex
        var output = Data()

        while true {
            guard let lineRange = data.range(of: lineSeparator, in: cursor..<data.endIndex) else {
                return nil
            }
            guard let line = String(
                data: Data(data[cursor..<lineRange.lowerBound]),
                encoding: .ascii
            ) else {
                throw CellularHTTPError.invalidResponse("Invalid chunk size.")
            }
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16), size >= 0 else {
                throw CellularHTTPError.invalidResponse("Invalid chunk size.")
            }
            cursor = lineRange.upperBound

            if size == 0 {
                while true {
                    guard let trailerRange = data.range(of: lineSeparator, in: cursor..<data.endIndex) else {
                        return nil
                    }
                    if trailerRange.lowerBound == cursor {
                        return output
                    }
                    cursor = trailerRange.upperBound
                }
            }

            guard size <= data.distance(from: cursor, to: data.endIndex) else {
                return nil
            }
            let chunkEnd = data.index(cursor, offsetBy: size)
            guard data.distance(from: chunkEnd, to: data.endIndex) >= 2,
                  data[chunkEnd] == 13,
                  data[data.index(after: chunkEnd)] == 10 else {
                return nil
            }
            output.append(contentsOf: data[cursor..<chunkEnd])
            cursor = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
