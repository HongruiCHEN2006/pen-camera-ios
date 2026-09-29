import Foundation
import XCTest
@testable import PenCamera

final class JPEGFrameAssemblerTests: XCTestCase {
    func testReassemblesMarkerSplitAcrossArbitraryChunks() {
        var assembler = JPEGFrameAssembler()
        XCTAssertTrue(assembler.append(Data([0x00, 0xAA, 0xFF])).isEmpty)
        XCTAssertTrue(assembler.append(Data([0xD8, 0x10, 0x20, 0xFF])).isEmpty)
        XCTAssertEqual(
            assembler.append(Data([0xD9, 0x99])),
            [Data([0xFF, 0xD8, 0x10, 0x20, 0xFF, 0xD9])]
        )
    }

    func testReturnsMultipleFramesFromOnePayload() {
        var assembler = JPEGFrameAssembler()
        let first = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let second = Data([0xFF, 0xD8, 0x02, 0xFF, 0xD9])
        XCTAssertEqual(assembler.append(first + second), [first, second])
    }

    func testNewStartDropsIncompleteFrameAndResynchronizes() {
        var assembler = JPEGFrameAssembler()
        let valid = Data([0xFF, 0xD8, 0x22, 0xFF, 0xD9])
        let bytes = Data([0xFF, 0xD8, 0x11, 0x11]) + valid
        XCTAssertEqual(assembler.append(bytes), [valid])
        XCTAssertEqual(assembler.droppedFrameCount, 1)
    }

    func testOversizedIncompleteFrameIsDiscarded() {
        var assembler = JPEGFrameAssembler(maximumFrameLength: 5)
        XCTAssertTrue(assembler.append(Data([0xFF, 0xD8, 1, 2, 3, 4])).isEmpty)
        XCTAssertEqual(assembler.droppedFrameCount, 1)
    }
}
