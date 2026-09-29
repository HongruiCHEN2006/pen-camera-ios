import Foundation
import XCTest
@testable import PenCamera

final class NaxProtocolTests: XCTestCase {
    private let unixTime = 1_720_000_000

    func testRequestsMatchPythonReferenceBytes() {
        XCTAssertEqual(
            NaxRequestFactory.liveMotion().encoded().hex,
            "0000000073000000303030303030303000000000"
        )
        XCTAssertEqual(
            NaxRequestFactory.heartbeat().encoded().hex,
            "0000000064000000303030303030303000000000"
        )
        XCTAssertEqual(
            NaxRequestFactory.connect(unixTime: unixTime).encoded().hex,
            "5b000000000000003030303030303030000000007b22636f6465223a203530312c2022746172676574223a20226465616462656566222c2022746f6b656e223a202254686973206973205445535420746f6b656e222c2022756e697854696d6572223a20313732303030303030307d"
        )
        XCTAssertEqual(
            NaxRequestFactory.baseInfo(unixTime: unixTime).encoded().hex,
            "57000000000000003030303030303030000000007b22636f6465223a203530322c2022636f6e74656e74223a207b22636f6465223a20342c2022646576546172676574223a20226465616462656566222c2022756e697854696d6572223a20313732303030303030307d7d"
        )
        XCTAssertEqual(
            NaxRequestFactory.openVideo().encoded().hex,
            "3e000000000000003030303030303030000000007b22636f6465223a203530322c2022636f6e74656e74223a207b22636f6465223a20332c2022646576546172676574223a20226465616462656566227d7d"
        )
    }

    func testParserAcceptsOneByteTCPFragmentsAndMultiplePackets() throws {
        let expected = [
            NaxPacket(command: NaxCommand.liveMotion),
            NaxPacket(command: NaxCommand.jpeg, payload: Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9]))
        ]
        let stream = expected.reduce(into: Data()) { $0.append($1.encoded()) }
        var parser = NaxPacketParser()
        var actual = [NaxPacket]()

        for byte in stream {
            actual.append(contentsOf: try parser.append(Data([byte])))
        }

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testParserRejectsImpossiblePayloadLength() {
        var parser = NaxPacketParser(maximumPayloadLength: 32)
        let header = Data([0x21, 0, 0, 0] + Array(repeating: 0, count: 16))
        XCTAssertThrowsError(try parser.append(header)) { error in
            XCTAssertEqual(error as? NaxProtocolError, .payloadTooLarge(33))
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
