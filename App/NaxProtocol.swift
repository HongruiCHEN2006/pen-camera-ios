import Foundation

enum NaxCommand {
    static let json: UInt16 = 0
    static let jpeg: UInt16 = 1
    static let audio: UInt16 = 4
    static let heartbeat: UInt16 = 100
    static let directMotion: UInt16 = 114
    static let liveMotion: UInt16 = 115
}

struct NaxPacket: Equatable {
    static let headerLength = 20
    static let defaultForwardID = Data("00000000".utf8)

    let command: UInt16
    let messageFlag: UInt8
    let dealFlag: UInt8
    let forwardID: Data
    let packageID: UInt32
    let payload: Data

    init(
        command: UInt16,
        messageFlag: UInt8 = 0,
        dealFlag: UInt8 = 0,
        forwardID: Data = NaxPacket.defaultForwardID,
        packageID: UInt32 = 0,
        payload: Data = Data()
    ) {
        self.command = command
        self.messageFlag = messageFlag
        self.dealFlag = dealFlag
        self.forwardID = forwardID
        self.packageID = packageID
        self.payload = payload
    }

    func encoded() -> Data {
        precondition(forwardID.count == 8, "Nax forward ID must contain exactly 8 bytes")
        precondition(payload.count <= Int(UInt32.max), "Nax payload is too large")

        var result = Data(capacity: Self.headerLength + payload.count)
        result.appendLittleEndian(UInt32(payload.count))
        result.appendLittleEndian(command)
        result.append(messageFlag)
        result.append(dealFlag)
        result.append(forwardID)
        result.appendLittleEndian(packageID)
        result.append(payload)
        return result
    }
}

enum NaxProtocolError: LocalizedError, Equatable {
    case payloadTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case let .payloadTooLarge(length):
            return "Nax packet declared an invalid payload length of \(length) bytes."
        }
    }
}

struct NaxPacketParser {
    private(set) var bufferedByteCount = 0
    private var buffer = [UInt8]()
    let maximumPayloadLength: Int

    init(maximumPayloadLength: Int = 8 * 1_024 * 1_024) {
        self.maximumPayloadLength = maximumPayloadLength
    }

    mutating func append(_ data: Data) throws -> [NaxPacket] {
        buffer.append(contentsOf: data)
        var packets = [NaxPacket]()

        while buffer.count >= NaxPacket.headerLength {
            let payloadLength = Int(readUInt32(at: 0))
            guard payloadLength <= maximumPayloadLength else {
                throw NaxProtocolError.payloadTooLarge(payloadLength)
            }

            let packetLength = NaxPacket.headerLength + payloadLength
            guard buffer.count >= packetLength else { break }

            let command = readUInt16(at: 4)
            let messageFlag = buffer[6]
            let dealFlag = buffer[7]
            let forwardID = Data(buffer[8..<16])
            let packageID = readUInt32(at: 16)
            let payload = Data(buffer[NaxPacket.headerLength..<packetLength])

            packets.append(
                NaxPacket(
                    command: command,
                    messageFlag: messageFlag,
                    dealFlag: dealFlag,
                    forwardID: forwardID,
                    packageID: packageID,
                    payload: payload
                )
            )
            buffer.removeFirst(packetLength)
        }

        bufferedByteCount = buffer.count
        return packets
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        bufferedByteCount = 0
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16)
            | (UInt32(buffer[offset + 3]) << 24)
    }
}

enum NaxRequestFactory {
    static let deviceTarget = "deadbeef"
    static let deviceToken = "This is TEST token"

    static func liveMotion() -> NaxPacket {
        NaxPacket(command: NaxCommand.liveMotion)
    }

    static func heartbeat() -> NaxPacket {
        NaxPacket(command: NaxCommand.heartbeat)
    }

    static func connect(unixTime: Int) -> NaxPacket {
        jsonPacket(
            "{\"code\": 501, \"target\": \"\(deviceTarget)\", \"token\": \"\(deviceToken)\", \"unixTimer\": \(unixTime)}"
        )
    }

    static func baseInfo(unixTime: Int) -> NaxPacket {
        jsonPacket(
            "{\"code\": 502, \"content\": {\"code\": 4, \"devTarget\": \"\(deviceTarget)\", \"unixTimer\": \(unixTime)}}"
        )
    }

    static func openVideo() -> NaxPacket {
        jsonPacket(
            "{\"code\": 502, \"content\": {\"code\": 3, \"devTarget\": \"\(deviceTarget)\"}}"
        )
    }

    private static func jsonPacket(_ json: String) -> NaxPacket {
        NaxPacket(command: NaxCommand.json, payload: Data(json.utf8))
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
